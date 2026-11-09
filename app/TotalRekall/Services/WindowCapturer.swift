// WindowCapturer.swift
// Enumerates windows (CGWindowListCopyWindowInfo, all Spaces), joins them to AX elements by
// CGWindowID, and turns them into WindowSnapshots. Proven live on real hardware, including the
// snapshot command. The filtering and assignment logic is pure so tests can feed
// fixture dictionaries shaped like real CG output; the live providers are thin and injected.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Value types

/// One CG window record, reduced to what snapshotting needs.
struct CGWindowInfo: Equatable, Sendable {
    let windowID: UInt32
    let ownerPID: Int32
    let ownerName: String
    let bundleID: String?
    let title: String?
    let frame: SnapshotFrame
    let layer: Int
    let alpha: Double
    let onScreen: Bool
}

/// What AX reports for a window that could be joined by CGWindowID. `nil` members = unmeasured.
struct AXWindowState: Equatable, Sendable {
    var minimized: Bool?
    var fullscreen: Bool?
}

/// One app's AX probe: the joined windows plus the raw AXError (`AXError.rawValue`) when the app's
/// window list could not be read. Codes only, never titles.
struct AXProbeResult: Equatable, Sendable {
    var states: [UInt32: AXWindowState]
    var errorCode: Int32?
}

/// How well a capture's CG candidates joined to AX. Counts and an error code only (trail-safe).
struct CaptureJoinStats: Equatable, Sendable {
    /// CG candidate windows after the cheap filter (own windows excluded).
    let candidates: Int
    /// Candidates whose CGWindowID matched an AX window.
    let axJoined: Int
    /// First AXError raw value seen across the probed apps, if any.
    let firstAXError: Int32?
}

/// A connected display with the identity data snapshotting needs.
struct LiveDisplay: Equatable, Sendable {
    let displayID: UInt32
    let serial: PanelIdentity.Serial
    /// Global point coordinates (top-left origin), as CGDisplayBounds reports.
    let frame: SnapshotFrame
    let pixelSize: SnapshotSize
    let scaleFactor: Double
    let name: String
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: String
    let unitNumber: UInt32
    let isMain: Bool

    /// Serial string used in keys, nil when unreadable (never guessed).
    var serialString: String? {
        switch serial {
        case .builtin: "builtin"
        case .panel(let s): s
        case .unavailable: nil
        }
    }
}

/// Monitor layout at capture time: panel serial to origin. Feeds the learned-layout rule.
struct MonitorLayout: Equatable, Sendable {
    struct Origin: Equatable, Sendable, Hashable {
        let x: Int
        let y: Int
    }
    var origins: [String: Origin]

    static func from(displays: [LiveDisplay]) -> MonitorLayout {
        var map: [String: Origin] = [:]
        for d in displays {
            if let s = d.serialString { map[s] = Origin(x: Int(d.frame.x), y: Int(d.frame.y)) }
        }
        return MonitorLayout(origins: map)
    }
}

// MARK: - Injection seams

protocol WindowListProviding: Sendable {
    func windowList() -> [CGWindowInfo]
}

protocol AXWindowProbing: Sendable {
    /// False when the private CGWindowID join is unavailable on this macOS build.
    var isAvailable: Bool { get }
    func states(pid: Int32) -> [UInt32: AXWindowState]
    /// `states` plus the AXError when the app's window list could not be read.
    func probe(pid: Int32) -> AXProbeResult
}

extension AXWindowProbing {
    /// Fakes that only model states report no error.
    func probe(pid: Int32) -> AXProbeResult { AXProbeResult(states: states(pid: pid), errorCode: nil) }
}

protocol DisplayProviding: Sendable {
    func currentDisplays() -> [LiveDisplay]
}

// MARK: - Pure logic + live CG parsing

enum WindowCapturer {
    static let minRestorableWidth = 100.0
    static let minRestorableHeight = 50.0

    // MARK: Parsing

    /// Parses one CGWindowListCopyWindowInfo dictionary. Nil when required keys are missing.
    static func parse(_ dict: [String: Any], bundleID: (Int32) -> String?) -> CGWindowInfo? {
        guard let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let wid = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let bounds = dict[kCGWindowBounds as String] as? [String: Any]
        else { return nil }
        func num(_ key: String) -> Double { (bounds[key] as? NSNumber)?.doubleValue ?? 0 }
        return CGWindowInfo(
            windowID: wid,
            ownerPID: pid,
            ownerName: dict[kCGWindowOwnerName as String] as? String ?? "<unknown>",
            bundleID: bundleID(pid),
            title: dict[kCGWindowName as String] as? String,
            frame: SnapshotFrame(x: num("X"), y: num("Y"), width: num("Width"), height: num("Height")),
            layer: (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            alpha: (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0,
            onScreen: (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        )
    }

    /// Parses a whole raw list, preserving CG order (front to back).
    static func parseList(_ raw: [[String: Any]], bundleID: (Int32) -> String?) -> [CGWindowInfo] {
        raw.compactMap { parse($0, bundleID: bundleID) }
    }

    // MARK: Filtering

    /// Cheap pre-AX filter: layer 0, visible alpha, not tiny, has a bundle ID, and not owned by
    /// `ownPID` (Total Rekall's own windows are never user windows to restore; CG also reports a
    /// title for them when it reports none for other apps, so they would survive a collapsed AX join).
    /// Matched by pid, not bundle ID, so Debug and DMG builds are covered too.
    /// (Untitled windows are decided later, once AX matching is known.)
    static func isCandidate(_ w: CGWindowInfo, excludingOwnerPID ownPID: Int32? = nil) -> Bool {
        w.layer == 0
            && w.alpha > 0
            && w.frame.width >= minRestorableWidth
            && w.frame.height >= minRestorableHeight
            && !(w.bundleID ?? "").isEmpty
            && w.ownerPID != ownPID
    }

    /// True when the AX join cannot be trusted: at least one candidate belongs to another app, yet AX
    /// returned no windows for any probed app (seen while the session is locked with the screens
    /// asleep). A capture in this state would keep only titled windows, so it must not be written.
    /// Shared by the capture guard and the session-readiness probe.
    static func axJoinCollapsed(candidates: [CGWindowInfo], axStates: [UInt32: AXWindowState],
                                ownerPID: Int32) -> Bool {
        candidates.contains { $0.ownerPID != ownerPID } && axStates.isEmpty
    }

    /// Join counts for the trail.
    static func joinStats(candidates: [CGWindowInfo], axStates: [UInt32: AXWindowState],
                          firstAXError: Int32?) -> CaptureJoinStats {
        CaptureJoinStats(candidates: candidates.count,
                         axJoined: candidates.filter { axStates[$0.windowID] != nil }.count,
                         firstAXError: firstAXError)
    }

    /// The `restorable` filter: candidate AND (AX-matched OR titled).
    /// Untitled windows AX cannot vouch for are helper surfaces, not user windows.
    static func isRestorable(_ w: CGWindowInfo, axMatched: Bool) -> Bool {
        isCandidate(w) && (axMatched || !(w.title ?? "").isEmpty)
    }

    // MARK: Assignment

    /// Builds WindowSnapshots from filtered CG windows. Pure.
    /// - Parameters:
    ///   - axStates: per-window AX state keyed by CGWindowID (join by ID, never by index).
    ///   - spaceIDs: SLS Space ids per window id (several = sticky).
    static func assemble(
        windows: [CGWindowInfo],
        axStates: [UInt32: AXWindowState],
        spaceIDs: [UInt32: [UInt64]],
        displays: [LiveDisplay],
        topology: [DisplaySpaces],
        fingerprint: String,
        makeID: () -> UUID = { UUID() }
    ) -> [WindowSnapshot] {
        var result: [WindowSnapshot] = []
        var perAppIndex: [String: Int] = [:]

        for (zOrder, w) in windows.enumerated() {
            let ax = axStates[w.windowID]
            guard isRestorable(w, axMatched: ax != nil), let bundleID = w.bundleID else { continue }

            let index = perAppIndex[bundleID, default: 0]
            perAppIndex[bundleID] = index + 1

            var distinct: [UInt64] = []
            for id in spaceIDs[w.windowID] ?? [] where !distinct.contains(id) { distinct.append(id) }
            let sticky = distinct.count > 1

            var desktop: DesktopKey?
            var notUserSpace = false
            var monitorSerial: String?
            if distinct.count == 1 {
                switch SpaceTopology.key(of: distinct[0], in: topology) {
                case .key(let k):
                    desktop = k
                    monitorSerial = k.panelSerial
                case .notUserSpace:
                    notUserSpace = true
                    monitorSerial = owningSerial(of: distinct[0], in: topology)
                case .serialUnavailable, .spaceNotFound:
                    break
                }
            }
            if monitorSerial == nil { monitorSerial = serialContaining(w.frame, in: displays) }

            let skip: WindowSkipReason?
            if ax?.minimized == true {
                skip = .minimized
            } else if ax?.fullscreen == true || notUserSpace {
                skip = .fullscreen
            } else {
                skip = nil
            }

            let displayIndex = displays.firstIndex { $0.serialString == monitorSerial && monitorSerial != nil } ?? -1

            result.append(WindowSnapshot(
                id: makeID(),
                bundleID: bundleID,
                appName: w.ownerName,
                windowID: w.windowID,
                windowTitle: w.title ?? "",
                windowIndex: index,
                displayFingerprint: fingerprint,
                displayIndex: displayIndex,
                panelSerial: monitorSerial,
                spaceOrdinal: desktop?.ordinal,
                spaceUUID: nil,
                spaceIndex: desktop.map { $0.ordinal - 1 } ?? -1,
                frame: w.frame,
                isFullscreen: skip == .fullscreen,
                isMinimized: skip == .minimized,
                zOrder: zOrder,
                sticky: sticky,
                axVisible: ax != nil,
                skipReason: skip
            ))
        }
        return result
    }

    /// Serial of the display holding a Space (even a non-user one).
    static func owningSerial(of id64: UInt64, in topology: [DisplaySpaces]) -> String? {
        guard let d = topology.first(where: { $0.spaces.contains { $0.id64 == id64 } }) else { return nil }
        switch d.serial {
        case .builtin: return "builtin"
        case .panel(let s): return s
        case .unavailable: return nil
        }
    }

    /// Serial of the display containing the frame's center, if any.
    static func serialContaining(_ frame: SnapshotFrame, in displays: [LiveDisplay]) -> String? {
        let cx = frame.x + frame.width / 2
        let cy = frame.y + frame.height / 2
        return displays.first { d in
            cx >= d.frame.x && cx < d.frame.x + d.frame.width
                && cy >= d.frame.y && cy < d.frame.y + d.frame.height
        }?.serialString
    }
}

// MARK: - Live providers

/// CGWindowListCopyWindowInfo(.optionAll): every Space, minimized included. Layer filtering happens
/// in `WindowCapturer.isCandidate`.
struct LiveWindowListProvider: WindowListProviding {
    func windowList() -> [CGWindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return WindowCapturer.parseList(raw) { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    }
}

/// AX probe over `AXWindowID`. Fullscreen reads the "AXFullScreen" attribute. [UNVERIFIED on macOS 27]
struct LiveAXWindowProbe: AXWindowProbing {
    var isAvailable: Bool { AXWindowID.isAvailable }

    func states(pid: Int32) -> [UInt32: AXWindowState] {
        probe(pid: pid).states
    }

    func probe(pid: Int32) -> AXProbeResult {
        let read = AXWindowID.copyWindows(pid: pid)
        var map: [UInt32: AXWindowState] = [:]
        for element in read.windows {
            guard let wid = AXWindowID.windowID(of: element) else { continue }
            map[wid] = AXWindowState(
                minimized: Self.bool(element, kAXMinimizedAttribute),
                fullscreen: Self.bool(element, "AXFullScreen")
            )
        }
        return AXProbeResult(states: map, errorCode: read.error?.rawValue)
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}

/// CoreGraphics-only display enumeration (no AppKit), paired with panel serials.
struct LiveDisplayProvider: DisplayProviding {
    func currentDisplays() -> [LiveDisplay] {
        let pairing = PanelIdentity.livePairing()
        let result: [LiveDisplay] = PanelIdentity.liveDisplays().map { input in
            let id = input.displayID
            let bounds = CGDisplayBounds(id)
            let pixelWidth = CGDisplayCopyDisplayMode(id).map { Double($0.pixelWidth) } ?? bounds.width
            let pixelHeight = CGDisplayCopyDisplayMode(id).map { Double($0.pixelHeight) } ?? bounds.height
            let serialNumber = CGDisplaySerialNumber(id)
            return LiveDisplay(
                displayID: id,
                serial: pairing.serialByDisplayID[id] ?? .unavailable,
                frame: SnapshotFrame(x: bounds.origin.x, y: bounds.origin.y,
                                     width: bounds.width, height: bounds.height),
                pixelSize: SnapshotSize(width: pixelWidth, height: pixelHeight),
                scaleFactor: bounds.width > 0 ? pixelWidth / bounds.width : 1,
                name: input.isBuiltin ? "Built-in Display" : "Display \(id)",
                vendorID: CGDisplayVendorNumber(id),
                productID: CGDisplayModelNumber(id),
                serialNumber: serialNumber == 0 ? "" : String(serialNumber),
                unitNumber: input.unitNumber,
                isMain: CGDisplayIsMain(id) != 0
            )
        }
        return result.sorted { ($0.frame.x, $0.frame.y) < ($1.frame.x, $1.frame.y) }
    }
}
