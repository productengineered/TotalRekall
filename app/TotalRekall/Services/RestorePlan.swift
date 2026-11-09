// RestorePlan.swift
// Pure restore planning: (snapshot windows, live windows, live Space topology, bridge capability)
// -> a per-window action list. No AX, CG or SkyLight calls here, so every branch is unit-testable.
// Matching is by CGWindowID only (v1.2). Execution lives in the restore engine.

import Foundation

/// Why a window is left where it is. Raw values are the strings written to the restore log.
enum RestoreSkipReason: String, Codable, Sendable, Hashable {
    case minimized
    case fullscreen
    case sticky
    /// The saved desktop ordinal no longer exists on that panel. The window stays put and is reported.
    case desktopMissing = "desktop-missing"
    case panelNotConnected = "panel-not-connected"
    case notFound = "not-found"
    /// Untitled and never AX-matched at capture: likely a helper surface (hidden/utility window,
    /// tab-group proxy). Bring-to-current would pull it across desktops for nothing.
    case untitledNoAXMatch = "untitled-no-ax-match"
}

/// The live state of one window, joined from CG (frame), SLS (Spaces) and AX (reachability).
struct LiveWindowState: Equatable, Sendable {
    let windowID: UInt32
    let frame: SnapshotFrame
    /// False when AX cannot see the window (it lives on another desktop).
    let axVisible: Bool
    /// SLS Space ids the window is on; several means sticky. Empty means unknown.
    let spaceIDs: [UInt64]

    init(windowID: UInt32, frame: SnapshotFrame, axVisible: Bool, spaceIDs: [UInt64]) {
        self.windowID = windowID
        self.frame = frame
        self.axVisible = axVisible
        self.spaceIDs = spaceIDs
    }
}

enum PlannedAction: Equatable, Sendable {
    /// Already on the right desktop and within tolerance of the saved frame.
    case alreadyCorrect
    /// Reposition through AX only (window is AX-reachable on its current desktop).
    case frameFix(SnapshotFrame)
    /// Move to the saved desktop; `frame` is non-nil when a frame fix follows the move.
    case moveSpace(spaceID: UInt64, desktop: DesktopKey, frame: SnapshotFrame?)
    /// Not AX-visible: bring to the current Space, fix the frame, then return it to `returnSpaceID`.
    case bringToCurrent(returnSpaceID: UInt64?, frame: SnapshotFrame)
    case skip(RestoreSkipReason)
}

struct PlannedWindow: Equatable, Sendable, Identifiable {
    var id: UUID { snapshotID }
    let snapshotID: UUID
    let windowID: UInt32?
    let bundleID: String
    let appName: String
    let title: String
    let action: PlannedAction
}

/// All windows that must reach one target desktop, so the engine can issue one move per desktop.
struct SpaceMoveGroup: Equatable, Sendable {
    let desktop: DesktopKey
    let spaceID: UInt64
    let windowIDs: [UInt32]
}

struct RestorePlan: Equatable, Sendable {
    let windows: [PlannedWindow]
    let capability: SpaceBridgeCapability

    /// Space moves grouped by target desktop (panel serial, then ordinal; window ids ascending).
    var spaceMoveGroups: [SpaceMoveGroup] {
        var grouped: [DesktopKey: (UInt64, [UInt32])] = [:]
        for w in windows {
            guard case .moveSpace(let spaceID, let desktop, _) = w.action, let wid = w.windowID else { continue }
            grouped[desktop, default: (spaceID, [])].1.append(wid)
        }
        return grouped
            .map { SpaceMoveGroup(desktop: $0.key, spaceID: $0.value.0, windowIDs: $0.value.1.sorted()) }
            .sorted { ($0.desktop.panelSerial, $0.desktop.ordinal) < ($1.desktop.panelSerial, $1.desktop.ordinal) }
    }

    var hasWork: Bool {
        windows.contains {
            switch $0.action {
            case .frameFix, .moveSpace, .bringToCurrent: true
            case .alreadyCorrect, .skip: false
            }
        }
    }

    static let defaultFrameTolerance = 2.0

    static func build(
        snapshot: [WindowSnapshot],
        live: [LiveWindowState],
        topology: [DisplaySpaces],
        capability: SpaceBridgeCapability,
        frameTolerance: Double = RestorePlan.defaultFrameTolerance
    ) -> RestorePlan {
        var liveByID: [UInt32: LiveWindowState] = [:]
        for w in live { liveByID[w.windowID] = w }
        let connected = Set(topology.compactMap { serialString($0.serial) })
        let canMoveSpaces = capability == .full

        let planned = snapshot.map { saved -> PlannedWindow in
            let action = action(for: saved, live: liveByID, topology: topology, connected: connected,
                                canMoveSpaces: canMoveSpaces, tolerance: frameTolerance)
            return PlannedWindow(snapshotID: saved.id, windowID: saved.windowID, bundleID: saved.bundleID,
                                 appName: saved.appName, title: saved.windowTitle, action: action)
        }
        return RestorePlan(windows: planned, capability: capability)
    }

    // MARK: - Per-window decision

    private static func action(
        for saved: WindowSnapshot,
        live: [UInt32: LiveWindowState],
        topology: [DisplaySpaces],
        connected: Set<String>,
        canMoveSpaces: Bool,
        tolerance: Double
    ) -> PlannedAction {
        // Recorded-state skips first: these never touch the window, found or not.
        if saved.isMinimized || saved.skipReason == .minimized { return .skip(.minimized) }
        if saved.isFullscreen || saved.skipReason == .fullscreen { return .skip(.fullscreen) }
        if saved.sticky == true { return .skip(.sticky) }

        guard let wid = saved.windowID, let current = live[wid] else { return .skip(.notFound) }
        if current.spaceIDs.count > 1 { return .skip(.sticky) }

        var target: (spaceID: UInt64, desktop: DesktopKey)?
        if let desktop = saved.desktopKey {
            guard connected.contains(desktop.panelSerial) else { return .skip(.panelNotConnected) }
            guard let spaceID = SpaceTopology.spaceID(for: desktop, in: topology) else { return .skip(.desktopMissing) }
            target = (spaceID, desktop)
        }

        let frameOK = framesMatch(current.frame, saved.frame, tolerance: tolerance)
        let onTarget = target.map { current.spaceIDs.contains($0.spaceID) } ?? true
        // An unknown current Space (empty) is treated as "not confirmed on target".
        let needsMove = canMoveSpaces && target != nil && !onTarget

        // Bring-to-current only for windows AX has vouched for at capture, or that carry a title.
        let bringable = !saved.windowTitle.isEmpty || saved.axVisible == true

        if needsMove, let target {
            if current.axVisible || frameOK {
                return .moveSpace(spaceID: target.spaceID, desktop: target.desktop, frame: frameOK ? nil : saved.frame)
            }
            guard bringable else { return .skip(.untitledNoAXMatch) }
            return .bringToCurrent(returnSpaceID: target.spaceID, frame: saved.frame)
        }
        if frameOK { return .alreadyCorrect }
        if current.axVisible { return .frameFix(saved.frame) }
        // Hidden window with a wrong frame: reachable only by pulling it to the current Space.
        if canMoveSpaces {
            guard bringable else { return .skip(.untitledNoAXMatch) }
            return .bringToCurrent(returnSpaceID: current.spaceIDs.first, frame: saved.frame)
        }
        // positionOnly: no Space moves; attempt AX and let the result report ax-unreachable.
        return .frameFix(saved.frame)
    }

    static func framesMatch(_ a: SnapshotFrame, _ b: SnapshotFrame, tolerance: Double) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func serialString(_ serial: PanelIdentity.Serial) -> String? {
        switch serial {
        case .builtin: "builtin"
        case .panel(let s): s
        case .unavailable: nil
        }
    }
}
