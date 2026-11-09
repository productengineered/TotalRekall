// CycleContext.swift
// Why a restore cycle ran, and which cycle it was. Every automation cycle and every manual run gets
// one; the pair is written to restore-log.json and to the diagnostics trail so a log line can be tied
// back to its cause.

import Foundation

enum CycleTrigger: String, Codable, Sendable, CaseIterable {
    /// A display was plugged, unplugged or rearranged (re-dock).
    case displayChange = "display-change"
    /// A display change that followed the Mac waking from sleep within the attribution window.
    case wake
    /// The monitor check at app launch.
    case launch
    /// The user chose Restore Now or Fix Monitors.
    case manual
}

/// What only the automation cycle knows about whether a wake restore may stay quiet. The
/// restore pipeline adds the rest (monitor fix, snapshot, window results) in `QuietWakePolicy`.
struct QuietWakeEligibility: Codable, Equatable, Sendable {
    /// A display was added or removed in any display event folded into this cycle.
    let displaysAddedOrRemoved: Bool
    /// The cycle resumed only because the session-not-ready hold hit its time bound.
    let resumedByHoldBound: Bool
}

struct CycleContext: Codable, Equatable, Sendable {
    let trigger: CycleTrigger
    let cycleID: UUID
    let startedAt: Date
    /// Set by AutomationController right before it restores. Nil for manual and launch runs and in
    /// data written before quiet wake existed (decoded as absent), which can never be quiet.
    let quietWake: QuietWakeEligibility?

    init(trigger: CycleTrigger, cycleID: UUID = UUID(), startedAt: Date = Date(),
         quietWake: QuietWakeEligibility? = nil) {
        self.trigger = trigger
        self.cycleID = cycleID
        self.startedAt = startedAt
        self.quietWake = quietWake
    }

    /// The same cycle (ID, trigger, start) carrying the automation's quiet-wake facts.
    func with(quietWake eligibility: QuietWakeEligibility) -> CycleContext {
        CycleContext(trigger: trigger, cycleID: cycleID, startedAt: startedAt, quietWake: eligibility)
    }

    /// A fresh context for a user-initiated run.
    static func manual(startedAt: Date = Date()) -> CycleContext {
        CycleContext(trigger: .manual, startedAt: startedAt)
    }
}
