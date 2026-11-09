// SnapshotService.swift
// Assembles a guarded Snapshot from live window/display/Space data and hands it to SnapshotStore,
// which applies the zero-window and <50% guards. A capture that cannot be trusted (Accessibility
// revoked, no AX join, an AX join that came back empty for every app, unreadable panel serial, no
// topology) FAILS instead of writing a degraded snapshot to disk. Total Rekall's own windows are
// never captured.

import Foundation
import os

enum SnapshotReason: String, Sendable {
    case manual, periodic, displayChange, sleep, quit
}

enum SnapshotCaptureError: Error, Equatable, Sendable {
    case accessibilityNotGranted
    case axWindowJoinUnavailable
    case noDisplays
    case panelIdentityUnavailable
    case topologyUnavailable(String)
    case storeFailed(String)
    /// Other apps have windows but AX returned none for any of them (e.g. the session is locked
    /// with the screens asleep). Nothing is written.
    case axJoinCollapsed(CaptureJoinStats)

    /// Menu text for Save Snapshot Now when the failure has a plain explanation; nil = generic.
    var menuMessage: String? {
        switch self {
        case .axJoinCollapsed:
            String(localized: "Your windows can't be read right now. Your saved snapshot was kept.")
        default:
            nil
        }
    }
}

/// Store result plus the layout used, so the learned-layout rule can learn it.
struct SnapshotCaptureResult: Equatable, Sendable {
    let reason: SnapshotReason
    let outcome: SnapshotSaveOutcome
    let layout: MonitorLayout
    let configKey: String
    let windowCount: Int
    /// How the capture's candidates joined to AX (trail counts). Nil from fakes.
    var join: CaptureJoinStats?
}

actor SnapshotService {
    private static let logger = Logger(subsystem: "com.productengineered.TotalRekall", category: "snapshot")
    private let store: SnapshotStore
    private let bridge: SpaceBridge
    private let trust: AccessibilityTrustChecking
    private let windowList: WindowListProviding
    private let axProbe: AXWindowProbing
    private let displayProvider: DisplayProviding
    private let ownerPID: Int32
    private let now: @Sendable () -> Date

    init(
        store: SnapshotStore,
        bridge: SpaceBridge,
        trust: AccessibilityTrustChecking = SystemAccessibilityTrustChecker(),
        windowList: WindowListProviding = LiveWindowListProvider(),
        axProbe: AXWindowProbing = LiveAXWindowProbe(),
        displayProvider: DisplayProviding = LiveDisplayProvider(),
        ownerPID: Int32 = getpid(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ownerPID = ownerPID
        self.store = store
        self.bridge = bridge
        self.trust = trust
        self.windowList = windowList
        self.axProbe = axProbe
        self.displayProvider = displayProvider
        self.now = now
    }

    /// Captures live state and saves it through the store's gated commit. `token` must be taken
    /// before this call; a display callback at any point before the commit discards the capture
    /// (outcome `.discardedGateClosed`).
    func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult {
        guard trust.isProcessTrusted() else { throw SnapshotCaptureError.accessibilityNotGranted }
        guard axProbe.isAvailable else { throw SnapshotCaptureError.axWindowJoinUnavailable }

        let displays = displayProvider.currentDisplays()
        guard !displays.isEmpty else { throw SnapshotCaptureError.noDisplays }
        let serials = displays.compactMap(\.serialString)
        guard serials.count == displays.count else { throw SnapshotCaptureError.panelIdentityUnavailable }
        let key = SnapshotKey.make(panelSerials: serials)

        // SLS display identifier -> panel serial, resolved against the live displays.
        let online = displays.map(\.displayID)
        let serialByDisplayID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0.serial) })
        let topology: [DisplaySpaces]
        do {
            topology = try await bridge.displaySpaces { identifier in
                SLSDisplayIdentifier.displayID(for: identifier, online: online).flatMap { serialByDisplayID[$0] }
            }
        } catch {
            throw SnapshotCaptureError.topologyUnavailable("\(error)")
        }

        let joined = try joinedCandidates()
        let candidates = joined.candidates, axStates = joined.axStates, join = joined.stats
        var spaceIDs: [UInt32: [UInt64]] = [:]
        for w in candidates {
            do {
                spaceIDs[w.windowID] = try await bridge.spaceIDs(forWindows: [w.windowID])
            } catch {
                // A window without desktop keys would make a degraded snapshot; fail the capture instead.
                Self.logger.error("space lookup failed for window \(w.windowID): \(String(describing: error))")
                throw SnapshotCaptureError.topologyUnavailable("space lookup for window \(w.windowID): \(error)")
            }
        }

        let windows = WindowCapturer.assemble(
            windows: candidates, axStates: axStates, spaceIDs: spaceIDs,
            displays: displays, topology: topology, fingerprint: key
        )
        let date = now()
        let config = DisplayConfigSnapshot(
            fingerprint: key,
            displayConfigName: displays.map(\.name).joined(separator: " + "),
            displays: displays.map(Self.displaySnapshot),
            lastSnapshotDate: date,
            windows: windows,
            spacesManifest: Self.manifest(topology: topology, fingerprint: key, date: date)
        )

        let outcome: SnapshotSaveOutcome
        do {
            outcome = try await store.save(config, key: key, ifGate: token, acceptShrink: reason == .manual)
        } catch {
            throw SnapshotCaptureError.storeFailed("\(error)")
        }
        return SnapshotCaptureResult(
            reason: reason, outcome: outcome, layout: MonitorLayout.from(displays: displays),
            configKey: key, windowCount: windows.count, join: join
        )
    }

    /// CG candidates (own windows excluded) joined to AX by CGWindowID. Throws `axJoinCollapsed`
    /// when other apps have windows but AX returned none for any of them.
    private func joinedCandidates() throws -> JoinedCandidates {
        let ownPID = ownerPID
        let candidates = windowList.windowList().filter { WindowCapturer.isCandidate($0, excludingOwnerPID: ownPID) }
        var axStates: [UInt32: AXWindowState] = [:]
        var firstAXError: Int32?
        for pid in Set(candidates.map(\.ownerPID)).sorted() {
            let probe = axProbe.probe(pid: pid)
            axStates.merge(probe.states) { _, new in new }
            if firstAXError == nil { firstAXError = probe.errorCode }
        }
        let join = WindowCapturer.joinStats(candidates: candidates, axStates: axStates, firstAXError: firstAXError)
        if WindowCapturer.axJoinCollapsed(candidates: candidates, axStates: axStates, ownerPID: ownPID) {
            Self.logger.error("AX join empty for \(join.candidates) candidates; capture refused")
            throw SnapshotCaptureError.axJoinCollapsed(join)
        }
        return JoinedCandidates(candidates: candidates, axStates: axStates, stats: join)
    }

    private struct JoinedCandidates {
        let candidates: [CGWindowInfo]
        let axStates: [UInt32: AXWindowState]
        let stats: CaptureJoinStats
    }

    static func displaySnapshot(_ d: LiveDisplay) -> DisplaySnapshot {
        DisplaySnapshot(
            vendorID: d.vendorID, productID: d.productID, serialNumber: d.serialNumber,
            panelSerial: d.serialString, unitNumber: d.unitNumber, iokitLocationPath: nil,
            resolution: d.pixelSize, scaleFactor: d.scaleFactor, displayName: d.name,
            originX: Int(d.frame.x), originY: Int(d.frame.y), isMain: d.isMain, cgDisplayID: d.displayID
        )
    }

    static func manifest(topology: [DisplaySpaces], fingerprint: String, date: Date) -> SpacesManifest {
        var entries: [SpaceEntry] = []
        for d in topology {
            let serial: String? = switch d.serial {
            case .builtin: "builtin"
            case .panel(let s): s
            case .unavailable: nil
            }
            for (i, space) in d.spaces.enumerated() {
                let ordinal = d.userSpaces.firstIndex { $0.id64 == space.id64 }.map { $0 + 1 }
                entries.append(SpaceEntry(
                    panelSerial: serial, ordinal: ordinal, displayFingerprint: fingerprint,
                    indexOnDisplay: i, isFullscreen: space.type != 0, spaceUUID: nil
                ))
            }
        }
        return SpacesManifest(capturedAt: date, orderedSpaces: entries)
    }
}
