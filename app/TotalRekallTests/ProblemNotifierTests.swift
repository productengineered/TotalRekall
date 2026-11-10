import XCTest
import Synchronization
@testable import TotalRekall

private final class FakeNotificationCenter: UserNotificationCentering, Sendable {
    private struct State {
        var status: NotificationAuthorization
        var grant: Bool
        var statusCalls = 0
        var requests = 0
        var posted: [ProblemNotificationRequest] = []
        var addFails = false
    }
    private let state: Mutex<State>

    init(status: NotificationAuthorization, grant: Bool = true, addFails: Bool = false) {
        state = Mutex(State(status: status, grant: grant, addFails: addFails))
    }

    var calls: Int { state.withLock { $0.statusCalls + $0.requests + $0.posted.count } }
    var requests: Int { state.withLock { $0.requests } }
    var posted: [ProblemNotificationRequest] { state.withLock { $0.posted } }

    func authorizationStatus() async -> NotificationAuthorization {
        state.withLock { $0.statusCalls += 1; return $0.status }
    }

    func requestAuthorization() async throws -> Bool {
        state.withLock {
            $0.requests += 1
            $0.status = $0.grant ? .authorized : .denied
            return $0.grant
        }
    }

    func add(_ request: ProblemNotificationRequest) async throws {
        let fails = state.withLock { $0.addFails }
        if fails { throw NSError(domain: "fake", code: 1) }
        state.withLock { $0.posted.append(request) }
    }
}

final class ProblemNotifierTests: XCTestCase {
    private let problem = RestoreOutcome.restored(ProblemNotificationPolicyTests.summary([.moved, .failed]))

    func testConstructionMakesNoCenterCalls() {
        let center = FakeNotificationCenter(status: .notDetermined)
        _ = ProblemNotifier(center: center, diagnostics: RecordingDiagnostics())
        XCTAssertEqual(center.calls, 0)
    }

    func testNonQualifyingOutcomeNeverTouchesCenter() async {
        let center = FakeNotificationCenter(status: .notDetermined)
        let sut = ProblemNotifier(center: center, diagnostics: RecordingDiagnostics())
        await sut.notify(context: CycleContext(trigger: .manual), outcome: problem)
        await sut.notify(context: CycleContext(trigger: .wake), outcome: .noSnapshot)
        XCTAssertEqual(center.calls, 0)
    }

    func testFirstProblemRequestsThenPostsOnce() async {
        let center = FakeNotificationCenter(status: .notDetermined)
        let diag = RecordingDiagnostics()
        let sut = ProblemNotifier(center: center, diagnostics: diag)
        let context = CycleContext(trigger: .displayChange)
        await sut.notify(context: context, outcome: problem)
        XCTAssertEqual(center.requests, 1)
        XCTAssertEqual(center.posted.count, 1)
        XCTAssertEqual(center.posted.first?.identifier, "restore-problem-\(context.cycleID.uuidString)")
        XCTAssertEqual(center.posted.first?.cycleID, context.cycleID)
        XCTAssertEqual(diag.events.map(\.name), ["notification-posted"])
        XCTAssertEqual(diag.events.first?.cycleID, context.cycleID)

        await sut.notify(context: CycleContext(trigger: .wake), outcome: problem)
        XCTAssertEqual(center.requests, 1, "authorized now: no second request")
        XCTAssertEqual(center.posted.count, 2)
    }

    func testDenialRecordsOnceAndNeverAsksAgain() async {
        let center = FakeNotificationCenter(status: .notDetermined, grant: false)
        let diag = RecordingDiagnostics()
        let sut = ProblemNotifier(center: center, diagnostics: diag)
        for _ in 0..<3 { await sut.notify(context: CycleContext(trigger: .launch), outcome: problem) }
        XCTAssertEqual(center.requests, 1)
        XCTAssertTrue(center.posted.isEmpty)
        XCTAssertEqual(diag.events.map(\.name), ["notifications-denied"])
    }

    func testAlreadyDeniedNeverRequests() async {
        let center = FakeNotificationCenter(status: .denied)
        let sut = ProblemNotifier(center: center, diagnostics: RecordingDiagnostics())
        await sut.notify(context: CycleContext(trigger: .wake), outcome: problem)
        XCTAssertEqual(center.requests, 0)
        XCTAssertTrue(center.posted.isEmpty)
    }

    func testPostFailureIsRecorded() async {
        let center = FakeNotificationCenter(status: .authorized, addFails: true)
        let diag = RecordingDiagnostics()
        let sut = ProblemNotifier(center: center, diagnostics: diag)
        await sut.notify(context: CycleContext(trigger: .wake), outcome: problem)
        XCTAssertEqual(diag.events.map(\.name), ["notification-failed"])
    }

    func testNotificationContent() {
        let partial = RestoreOutcome.restored(ProblemNotificationPolicyTests.summary(
            Array(repeating: .moved, count: 22) + [.failed, .failed]))
        let content = ProblemNotificationPolicy.content(for: partial)
        XCTAssertEqual(content.title, "TotalRekall")
        XCTAssertEqual(content.body, "Partly restored. 22 of 24 windows.")

        let nothing = RestoreOutcome.restored(ProblemNotificationPolicyTests.summary([.failed, .failed]))
        XCTAssertEqual(ProblemNotificationPolicy.content(for: nothing).body,
                       "Couldn't restore. Open the restore log for details.")
        XCTAssertEqual(ProblemNotificationPolicy.content(for: .failed("x")).body,
                       "Couldn't restore. Open the restore log for details.")

        let fix = RestoreOutcome.monitorsFixed(.failed(reason: "x"), date: Date())
        XCTAssertEqual(ProblemNotificationPolicy.content(for: fix).body,
                       "Couldn't fix monitors. Open the restore log for details.")
        let cleanRestoreBadFix = RestoreOutcome.restored(ProblemNotificationPolicyTests.summary(
            [.moved, .moved], monitorFix: .failed(reason: "x")))
        XCTAssertEqual(ProblemNotificationPolicy.content(for: cleanRestoreBadFix).body,
                       "Couldn't fix monitors. Open the restore log for details.")
    }
}
