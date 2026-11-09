// LearnedLayoutStore.swift
// The "learned" monitor layout: the panel-serial -> origin map from the most recent successful
// snapshot taken OUTSIDE the pause. After a replug, SwapDetector compares the live layout against
// this value, which by construction is the layout learned BEFORE the change: `learn` re-checks the
// SnapshotGate token under the gate lock, so learning is frozen from the first display callback.
//
// ACCEPTED RISK: layout is learned automatically, so a swap that is already
// present at launch is learned as correct. The restore log should record which layout was used.
// In-memory only: relaunch re-learns from the first snapshot.

import Foundation

actor LearnedLayoutStore {
    private(set) var layout = MonitorLayout(origins: [:])
    private(set) var learnedAt: Date?

    init(initial: MonitorLayout = MonitorLayout(origins: [:])) {
        layout = initial
    }

    /// Layout to feed SwapDetector as `learned`.
    var layoutForSwapCheck: MonitorLayout { layout }

    /// Updates the learned layout only if the gate is still open at the token's epoch (checked
    /// atomically with the assignment). Empty layouts are never learned. Returns whether it learned.
    @discardableResult
    func learn(_ newLayout: MonitorLayout, at date: Date = Date(), ifGate token: SnapshotGateToken) -> Bool {
        guard !newLayout.origins.isEmpty else { return false }
        return token.commitIfValid {
            layout = newLayout
            learnedAt = date
        }
    }

    /// Escape hatch if the user permanently changes their docked set.
    func reset() {
        layout = MonitorLayout(origins: [:])
        learnedAt = nil
    }
}
