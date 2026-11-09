// SnapshotGate.swift
// THE single synchronous source of truth for the critical rule: from the FIRST display-change
// callback until the restore completes, no snapshot file may be written and the learned layout may
// not change.
//
//   close:  DisplayMonitor.receive, synchronously inside the CG callback / screen-parameters
//           notification, on the first (and every further) non-self-triggered raw event. Each close
//           bumps `epoch`. Self-suppressed callbacks never reach it.
//   reopen: ONLY AutomationController, after the restore cycle completes with no follow-up pending
//           (or after verifying the live layout matches the learned one when nothing needs
//           restoring), and only if no raw callback arrived after the last event it ingested
//           (`reopen(ifEpoch:)` is atomic with that check).
//   write:  every snapshot write and every learned-layout update re-checks `isOpen && epoch ==
//           token.epoch` under this lock, inside the writer's own isolation domain, immediately
//           before mutating (`SnapshotStore.save(_:key:ifGate:)`, `LearnedLayoutStore.learn`).
//           A failed check discards the capture.
//
//   hold:   an independent set of holds (`SnapshotHold`, e.g. `.screensAsleep`) that also blocks
//           writes, owned by SystemWakeObserver. Setting a hold bumps `epoch`, so an in-flight
//           capture or learn() is discarded. Clearing a hold NEVER opens the gate: a display-change
//           close stays closed until AutomationController reopens it. Holds do not touch `isOpen`,
//           `reason` or `displayEpoch`.
//
// Invariants:
//   - token() / isValid / runIfOpen require `isOpen && holds.isEmpty && epoch == token.epoch`.
//   - `reopen(ifEpoch:)` compares against `displayEpoch` (the epoch of the newest display close), so a
//     hold bump while closed can never wedge the reopen; a newer display callback still refuses it.
//   - Every close and every hold set moves `epoch` forward; nothing moves it back.
//
// The lock is held across the final rename of a snapshot file (temp files are staged outside it), so
// a callback either lands before the check (write discarded) or after the write completed (the data
// predates the change). Never call back into the gate from inside `runIfOpen`.

import Foundation
import Synchronization

/// A reason, independent of display changes, that snapshots may not be written right now.
enum SnapshotHold: String, Hashable, Sendable {
    /// Screens asleep or the session locked: AX cannot see other apps' windows.
    case screensAsleep = "screens-asleep"

    var refusal: SnapshotRefusal {
        switch self {
        case .screensAsleep: .screensAsleep
        }
    }
}

final class SnapshotGate: Sendable {
    struct Status: Equatable, Sendable {
        /// Display-change openness only. Writes also need `holds` to be empty.
        var isOpen: Bool
        var epoch: UInt64
        /// Why the gate is closed (menu message); nil while open.
        var reason: SnapshotRefusal?
        /// Epoch of the close that ended the last open period. Further raw callbacks while closed bump
        /// `epoch` but not this, so the trail reports one epoch per close/reopen pair.
        var closedEpoch: UInt64 = 0
        /// Active holds (independent of display closes).
        var holds: Set<SnapshotHold> = []
        /// Epoch of the newest display-change close; `reopen(ifEpoch:)` compares against it.
        var displayEpoch: UInt64 = 0

        /// True when a capture may take a token.
        var acceptsSnapshots: Bool { isOpen && holds.isEmpty }

        /// `closedEpoch` and `displayEpoch` are bookkeeping, not gate state, so they are excluded.
        static func == (lhs: Status, rhs: Status) -> Bool {
            lhs.isOpen == rhs.isOpen && lhs.epoch == rhs.epoch && lhs.reason == rhs.reason
                && lhs.holds == rhs.holds
        }
    }

    private let state: Mutex<Status>

    init() {
        state = Mutex(Status(isOpen: true, epoch: 0, reason: nil))
    }

    var status: Status { state.withLock { $0 } }
    var isOpen: Bool { state.withLock { $0.isOpen } }
    var epoch: UInt64 { state.withLock { $0.epoch } }
    var closedEpoch: UInt64 { state.withLock { $0.closedEpoch } }
    var holds: Set<SnapshotHold> { state.withLock { $0.holds } }
    /// Open for display changes AND no hold active.
    var acceptsSnapshots: Bool { state.withLock { $0.acceptsSnapshots } }

    /// Reason to show for a refused or discarded snapshot. A display close wins over a hold. An attempt
    /// invalidated by a change that already completed (gate reopened at a newer epoch) reports the
    /// display change.
    var refusal: SnapshotRefusal {
        state.withLock { status in
            if !status.isOpen { return status.reason ?? .displayChangeInProgress }
            if let hold = status.holds.sorted(by: { $0.rawValue < $1.rawValue }).first { return hold.refusal }
            return .displayChangeInProgress
        }
    }

    // MARK: Close (DisplayMonitor)

    /// Closes the gate for a raw display change and returns the new epoch. Synchronous: called from
    /// the CG reconfiguration callback before any debounce or async hop.
    @discardableResult
    func closeForDisplayChange() -> UInt64 {
        state.withLock { status in
            status.epoch &+= 1
            if status.isOpen { status.closedEpoch = status.epoch }
            status.isOpen = false
            status.reason = .displayChangeInProgress
            status.displayEpoch = status.epoch
            return status.epoch
        }
    }

    // MARK: Holds (SystemWakeObserver)

    /// Adds a hold and bumps the epoch, discarding any capture or learn() already in flight. Returns
    /// whether the hold was newly added.
    @discardableResult
    func setHold(_ hold: SnapshotHold) -> Bool {
        state.withLock { status in
            status.epoch &+= 1
            return status.holds.insert(hold).inserted
        }
    }

    /// Removes a hold. Never opens a display-change close and never touches the epoch. Returns whether
    /// the hold was present.
    @discardableResult
    func clearHold(_ hold: SnapshotHold) -> Bool {
        state.withLock { $0.holds.remove(hold) != nil }
    }

    // MARK: Label (AutomationController)

    /// Updates the menu-facing reason while closed. Never opens or closes the gate.
    func relabel(_ reason: SnapshotRefusal) {
        state.withLock { status in
            if !status.isOpen { status.reason = reason }
        }
    }

    // MARK: Reopen (AutomationController only)

    /// Opens the gate only if no raw display callback arrived after `epoch` (the newest epoch the
    /// caller has ingested). Hold bumps do not count as callbacks. Returns whether the gate is open
    /// afterwards (holds, if any, still block writes).
    @discardableResult
    func reopen(ifEpoch epoch: UInt64) -> Bool {
        state.withLock { status in
            guard status.displayEpoch == epoch else { return status.isOpen }
            status.isOpen = true
            status.reason = nil
            return true
        }
    }

    // MARK: Write tokens

    /// A token for one capture, or nil while closed or held. Take it BEFORE reading any live state.
    func token() -> SnapshotGateToken? {
        state.withLock { status in
            status.acceptsSnapshots ? SnapshotGateToken(gate: self, epoch: status.epoch) : nil
        }
    }

    func isValid(epoch: UInt64) -> Bool {
        state.withLock { $0.acceptsSnapshots && $0.epoch == epoch }
    }

    /// Runs `body` under the gate lock only if the gate is still open at `epoch`. Returns whether
    /// it ran. Keep `body` short (a rename, an assignment): the CG callback waits on this lock.
    func runIfOpen<E: Error>(epoch: UInt64, _ body: () throws(E) -> Void) throws(E) -> Bool {
        try state.withLock { status throws(E) -> Bool in
            guard status.acceptsSnapshots, status.epoch == epoch else { return false }
            try body()
            return true
        }
    }
}

/// Proof that the gate was open at `epoch` when a capture began. Writers re-check it at commit.
struct SnapshotGateToken: Sendable {
    let gate: SnapshotGate
    let epoch: UInt64

    var isValid: Bool { gate.isValid(epoch: epoch) }

    /// Runs `body` atomically with the validity check. Returns false (body not run) if the gate
    /// closed or moved to another epoch since the token was taken.
    func commitIfValid<E: Error>(_ body: () throws(E) -> Void) throws(E) -> Bool {
        try gate.runIfOpen(epoch: epoch, body)
    }
}
