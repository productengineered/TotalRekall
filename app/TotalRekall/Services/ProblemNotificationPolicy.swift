// ProblemNotificationPolicy.swift
// When a "something went wrong" notification is deserved, and how it is worded. Pure value logic:
// no UserNotifications import, so it is trivially testable.

import Foundation

struct ProblemNotificationContent: Equatable, Sendable {
    let title: String
    let body: String
}

enum ProblemNotificationPolicy {
    /// Only automatic cycles notify (the user is watching a manual run), and only when the outcome
    /// would also raise the menu's attention icon. A quiet wake never notifies, under any trigger.
    static func shouldNotify(trigger: CycleTrigger, outcome: RestoreOutcome) -> Bool {
        if case .quietWake = outcome { return false }
        return switch trigger {
        case .displayChange, .wake, .launch: outcome.setsAttention
        case .manual: false
        }
    }

    static let title = "TotalRekall"

    /// The notification text for an outcome that `shouldNotify` accepted.
    static func content(for outcome: RestoreOutcome) -> ProblemNotificationContent {
        ProblemNotificationContent(title: title, body: body(for: outcome))
    }

    private static func body(for outcome: RestoreOutcome) -> String {
        let couldntRestore = String(localized: "Couldn't restore. Open the restore log for details.")
        let couldntFixMonitors = String(localized: "Couldn't fix monitors. Open the restore log for details.")
        switch outcome {
        case .restored(let summary):
            if summary.isFailed || summary.restored == 0 && summary.total > 0 { return couldntRestore }
            if summary.isPartial {
                return String(localized: "Partly restored. \(summary.restored) of \(summary.total) windows.")
            }
            if summary.monitorFixFailed { return couldntFixMonitors }
            return String(localized: "Partly restored. \(summary.restored) of \(summary.total) windows.")
        case .monitorsFixed:
            return couldntFixMonitors
        case .quietWake, .failed, .refusedNoAccessibility, .droppedInFlight, .noSnapshot:
            return couldntRestore  // quietWake never reaches here: shouldNotify refuses it
        }
    }
}
