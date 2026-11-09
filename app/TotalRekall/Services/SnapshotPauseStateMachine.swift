// SnapshotPauseStateMachine.swift
// Pure phase model for the snapshot pause rule. A scrambled mid-replug state must never
// overwrite the good snapshot or the learned layout, so everything pauses from the FIRST display
// callback until the subsequent restore completes (or the change settles with nothing to restore).
//
// This machine LABELS the pause (menu message). It does not gate writes: `SnapshotGate` is the single
// synchronous source of truth. AutomationController owns one machine, applies its transitions
// alongside the gate, and only moves it to idle after `SnapshotGate.reopen(ifEpoch:)` succeeded.
//
//   idle --displayCallback--> changeInProgress --settled(needsRestore)--> awaitingRestore
//   changeInProgress --settled(no restore)--> idle
//   awaitingRestore --restoreStarted--> restoring --restoreFinished--> idle
//
// Any displayCallback while awaitingRestore re-enters changeInProgress (the layout moved again).
// A callback while restoring is ignored (the restore's own changes are expected; DisplayMonitor
// also suppresses them), and the state stays restoring.

import Foundation

enum SnapshotPauseState: Equatable, Sendable, CaseIterable {
    case idle
    case changeInProgress
    case awaitingRestore
    case restoring

    var isPaused: Bool { self != .idle }
}

enum SnapshotPauseEvent: Equatable, Sendable {
    /// First (or any further) raw display-change callback.
    case displayCallback
    /// The debounced change settled. `needsRestore` is true when a restore will follow.
    case displaySettled(needsRestore: Bool)
    case restoreStarted
    /// Restore ended, success or failure: snapshots resume either way.
    case restoreFinished(success: Bool)
}

/// Why a snapshot (scheduled or manual) was refused.
enum SnapshotRefusal: Equatable, Sendable {
    case displayChangeInProgress
    case awaitingRestore
    case restoring
    /// The learned docked set (panel serials) is not fully present, e.g. laptop-only.
    case dockedSetAbsent
    /// A display change happened while Accessibility was missing; held until it returns and a
    /// restore cycle runs.
    case accessibilityMissing
    /// Nothing was restored and the live monitor layout does not match the learned one.
    case layoutUnverified
    /// Screens asleep or the session locked (a `SnapshotHold`, not a display change).
    case screensAsleep
    /// A display change arrived while other apps' windows could not be read (e.g. still at the lock
    /// screen); the restore is held until they can.
    case sessionNotReady

    /// Menu-facing reason for a refused Save Snapshot Now.
    var message: String {
        switch self {
        case .displayChangeInProgress: "Displays are changing; snapshots are paused."
        case .awaitingRestore: "Waiting for the restore after a display change; snapshots are paused."
        case .restoring: "Restoring windows; snapshots are paused."
        case .dockedSetAbsent: "Docked monitors are not connected; snapshots are paused."
        case .accessibilityMissing: "Accessibility access is needed after a display change; snapshots are paused."
        case .layoutUnverified: "The monitor layout could not be verified after a display change; snapshots are paused."
        case .screensAsleep: "Screens are asleep or the Mac is locked; snapshots are paused."
        case .sessionNotReady: "Waiting until your windows can be read after a wake; snapshots are paused."
        }
    }
}

enum SnapshotGateDecision: Equatable, Sendable {
    case allowed
    case refused(SnapshotRefusal)
}

struct SnapshotPauseStateMachine: Equatable, Sendable {
    private(set) var state: SnapshotPauseState = .idle

    var isPaused: Bool { state.isPaused }

    mutating func handle(_ event: SnapshotPauseEvent) {
        switch (state, event) {
        case (.restoring, .displayCallback):
            break
        case (_, .displayCallback):
            state = .changeInProgress
        case (.changeInProgress, .displaySettled(let needsRestore)):
            state = needsRestore ? .awaitingRestore : .idle
        case (.awaitingRestore, .restoreStarted):
            state = .restoring
        case (.changeInProgress, .restoreStarted):
            // Restore requested before the settle event was seen; still paused.
            state = .restoring
        case (.restoring, .restoreFinished), (.awaitingRestore, .restoreFinished),
             (.changeInProgress, .restoreFinished):
            state = .idle
        default:
            break  // e.g. settled/restoreFinished while idle: nothing to do
        }
    }

    /// Pause label only (docked-set rule is layered on by `SnapshotPolicy.decide`).
    var pauseRefusal: SnapshotRefusal? {
        switch state {
        case .idle: nil
        case .changeInProgress: .displayChangeInProgress
        case .awaitingRestore: .awaitingRestore
        case .restoring: .restoring
        }
    }
}

/// Pure snapshot policy: the pause label plus the docked-set rule. Write gating lives in `SnapshotGate`.
enum SnapshotPolicy {
    /// Combines the pause state with the docked-set rule.
    static func decide(
        machine: SnapshotPauseStateMachine,
        learned: MonitorLayout,
        live: MonitorLayout
    ) -> SnapshotGateDecision {
        if let refusal = machine.pauseRefusal { return .refused(refusal) }
        if let refusal = dockedSetRefusal(learned: learned, live: live) { return .refused(refusal) }
        return .allowed
    }

    /// "Docked set" = the panel serials in the learned layout; if any is missing from the live layout,
    /// snapshots stay paused. An empty learned layout (first run) never blocks, otherwise nothing could
    /// ever be learned.
    static func dockedSetRefusal(learned: MonitorLayout, live: MonitorLayout) -> SnapshotRefusal? {
        guard !learned.origins.isEmpty else { return nil }
        return Set(learned.origins.keys).isSubset(of: Set(live.origins.keys)) ? nil : .dockedSetAbsent
    }
}
