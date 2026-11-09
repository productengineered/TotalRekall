import XCTest
import Synchronization
@testable import TotalRekall

private actor RecordingInnerStatus: AutomationStatusReporting {
    private(set) var finished: [(RestoreOutcome?, CycleTrigger?)] = []
    func automationDidBegin() async {}
    func automationDidFinish(outcome: RestoreOutcome?) async { finished.append((outcome, nil)) }
    func automationDidFinish(outcome: RestoreOutcome?, context: CycleContext) async {
        finished.append((outcome, context.trigger))
    }
}

private final class RecordingNotifier: ProblemNotifying, Sendable {
    private let calls = Mutex<[(CycleTrigger, RestoreOutcome)]>([])
    var received: [(CycleTrigger, RestoreOutcome)] { calls.withLock { $0 } }
    func notify(context: CycleContext, outcome: RestoreOutcome) async {
        calls.withLock { $0.append((context.trigger, outcome)) }
    }
}

private final class CountingCenter: UserNotificationCentering, Sendable {
    private let state = Mutex<(status: Int, posted: [ProblemNotificationRequest])>((0, []))
    var statusCalls: Int { state.withLock { $0.status } }
    var posted: [ProblemNotificationRequest] { state.withLock { $0.posted } }
    func authorizationStatus() async -> NotificationAuthorization {
        state.withLock { $0.status += 1 }
        return .authorized
    }
    func requestAuthorization() async throws -> Bool { true }
    func add(_ request: ProblemNotificationRequest) async throws { state.withLock { $0.posted.append(request) } }
}

final class ProblemNotificationWiringTests: XCTestCase {
    private let problem = RestoreOutcome.restored(ProblemNotificationPolicyTests.summary([.moved, .failed]))

    func testReporterPassesCycleTriggerAndOutcomeToNotifier() async {
        let inner = RecordingInnerStatus()
        let notifier = RecordingNotifier()
        let sut = NotifyingAutomationStatus(inner: inner, notifier: notifier)
        await sut.automationDidFinish(outcome: problem, context: CycleContext(trigger: .wake))
        await sut.waitForNotifications()
        XCTAssertEqual(notifier.received.map(\.0), [.wake])
        XCTAssertEqual(notifier.received.first?.1, problem)
        let innerTriggers = await inner.finished.map(\.1)
        XCTAssertEqual(innerTriggers, [.wake], "the menu reporter still sees the cycle first")
    }

    func testCycleWithoutOutcomeNeverNotifies() async {
        let notifier = RecordingNotifier()
        let sut = NotifyingAutomationStatus(inner: RecordingInnerStatus(), notifier: notifier)
        await sut.automationDidFinish(outcome: nil, context: CycleContext(trigger: .displayChange))
        await sut.waitForNotifications()
        XCTAssertTrue(notifier.received.isEmpty)
    }

    func testAutomaticProblemPostsExactlyOneNotification() async {
        let center = CountingCenter()
        let notifier = ProblemNotifier(center: center, diagnostics: RecordingDiagnostics())
        let sut = NotifyingAutomationStatus(inner: RecordingInnerStatus(), notifier: notifier)
        await sut.automationDidFinish(outcome: problem, context: CycleContext(trigger: .displayChange))
        await sut.waitForNotifications()
        XCTAssertEqual(center.posted.count, 1)
    }

    func testManualContextNeverPostsEvenIfItReachedTheReporter() async {
        let center = CountingCenter()
        let notifier = ProblemNotifier(center: center, diagnostics: RecordingDiagnostics())
        let sut = NotifyingAutomationStatus(inner: RecordingInnerStatus(), notifier: notifier)
        await sut.automationDidFinish(outcome: problem, context: .manual())
        await sut.waitForNotifications()
        XCTAssertEqual(center.statusCalls, 0)
        XCTAssertTrue(center.posted.isEmpty)
    }

    /// AC4: a quiet wake posts nothing; a non-quiet wake partial and a display-change partial post one
    /// each; a manual partial posts none.
    func testQuietWakePostsNoNotification() async {
        let quiet = RestoreOutcome.quietWake(
            ProblemNotificationPolicyTests.summary([.alreadyCorrect], monitorFix: .alreadyInOrder))
        let cases: [(RestoreOutcome, CycleContext, Int)] = [
            (quiet, CycleContext(trigger: .wake), 0),
            (problem, CycleContext(trigger: .wake), 1),
            (problem, CycleContext(trigger: .displayChange), 1),
            (problem, .manual(), 0)
        ]
        for (outcome, context, expected) in cases {
            let center = CountingCenter()
            let notifier = ProblemNotifier(center: center, diagnostics: RecordingDiagnostics())
            let sut = NotifyingAutomationStatus(inner: RecordingInnerStatus(), notifier: notifier)
            await sut.automationDidFinish(outcome: outcome, context: context)
            await sut.waitForNotifications()
            XCTAssertEqual(center.posted.count, expected, "\(context.trigger) \(outcome)")
        }
    }

    func testConstructingTheReporterAndNotifierMakesNoCenterCalls() {
        let center = CountingCenter()
        _ = NotifyingAutomationStatus(inner: RecordingInnerStatus(),
                                      notifier: ProblemNotifier(center: center, diagnostics: RecordingDiagnostics()))
        XCTAssertEqual(center.statusCalls, 0)
    }
}
