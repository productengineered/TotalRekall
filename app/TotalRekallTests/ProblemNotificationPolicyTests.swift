import XCTest
@testable import TotalRekall

final class ProblemNotificationPolicyTests: XCTestCase {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func summary(_ statuses: [RestoreStatus], monitorFix: FixOutcome? = nil) -> RestoreSummary {
        let results = statuses.enumerated().map { index, status in
            RestoreWindowResult(snapshotID: UUID(), windowID: UInt32(index + 1), bundleID: "com.example",
                                appName: "App", title: "t", status: status)
        }
        return RestoreSummary(results: results, date: date, monitorFix: monitorFix)
    }

    private var problemOutcomes: [RestoreOutcome] {
        [.restored(Self.summary([.moved, .failed])),
         .monitorsFixed(.failed(reason: "x"), date: Self.date),
         .monitorsFixed(.unverified(reason: "x"), date: Self.date),
         .failed("topology")]
    }

    private var quietOutcomes: [RestoreOutcome] {
        [.restored(Self.summary([.moved, .alreadyCorrect])),
         .monitorsFixed(.verified, date: Self.date),
         .monitorsFixed(.alreadyInOrder, date: Self.date),
         .noSnapshot, .droppedInFlight, .refusedNoAccessibility,
         .quietWake(Self.summary([.alreadyCorrect, .alreadyCorrect], monitorFix: .alreadyInOrder))]
    }

    func testAutomaticTriggersNotifyForProblemOutcomes() {
        for trigger in [CycleTrigger.displayChange, .wake, .launch] {
            for outcome in problemOutcomes {
                XCTAssertTrue(ProblemNotificationPolicy.shouldNotify(trigger: trigger, outcome: outcome),
                              "\(trigger) \(outcome)")
            }
        }
    }

    func testQuietOutcomesNeverNotify() {
        for trigger in CycleTrigger.allCases {
            for outcome in quietOutcomes {
                XCTAssertFalse(ProblemNotificationPolicy.shouldNotify(trigger: trigger, outcome: outcome),
                               "\(trigger) \(outcome)")
            }
        }
    }

    /// AC4: a quiet wake never notifies under any trigger, even if its summary would look like a problem.
    func testQuietWakeOutcomeNeverNotifiesUnderAnyTrigger() {
        let summaries = [Self.summary([.alreadyCorrect], monitorFix: .alreadyInOrder),
                         Self.summary([.moved, .failed], monitorFix: .failed(reason: "x"))]
        for trigger in CycleTrigger.allCases {
            for summary in summaries {
                XCTAssertFalse(ProblemNotificationPolicy.shouldNotify(trigger: trigger, outcome: .quietWake(summary)),
                               "\(trigger)")
            }
        }
    }

    func testManualNeverNotifies() {
        for outcome in problemOutcomes + quietOutcomes {
            XCTAssertFalse(ProblemNotificationPolicy.shouldNotify(trigger: .manual, outcome: outcome))
        }
    }

    func testSetsAttentionMirrorsMenuRules() {
        for outcome in problemOutcomes { XCTAssertTrue(outcome.setsAttention) }
        for outcome in quietOutcomes { XCTAssertFalse(outcome.setsAttention) }
    }
}
