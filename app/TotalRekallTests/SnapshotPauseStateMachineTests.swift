import Synchronization
import XCTest
@testable import TotalRekall

final class SnapshotPauseStateMachineTests: XCTestCase {
    private func layout(_ serials: [String]) -> MonitorLayout {
        var map: [String: MonitorLayout.Origin] = [:]
        for (i, s) in serials.enumerated() { map[s] = .init(x: i * 1000, y: 0) }
        return MonitorLayout(origins: map)
    }

    func testTransitionsThroughRestore() {
        var m = SnapshotPauseStateMachine()
        XCTAssertEqual(m.state, .idle)
        m.handle(.displayCallback); XCTAssertEqual(m.state, .changeInProgress)
        m.handle(.displayCallback); XCTAssertEqual(m.state, .changeInProgress)
        m.handle(.displaySettled(needsRestore: true)); XCTAssertEqual(m.state, .awaitingRestore)
        m.handle(.restoreStarted); XCTAssertEqual(m.state, .restoring)
        m.handle(.displayCallback); XCTAssertEqual(m.state, .restoring)
        m.handle(.restoreFinished(success: true)); XCTAssertEqual(m.state, .idle)
    }

    func testSettleWithNothingToRestoreResumes() {
        var m = SnapshotPauseStateMachine()
        m.handle(.displayCallback)
        m.handle(.displaySettled(needsRestore: false))
        XCTAssertEqual(m.state, .idle)
    }

    func testRestoreFailureAlsoResumes() {
        var m = SnapshotPauseStateMachine()
        m.handle(.displayCallback)
        m.handle(.displaySettled(needsRestore: true))
        m.handle(.restoreStarted)
        m.handle(.restoreFinished(success: false))
        XCTAssertFalse(m.isPaused)
    }

    func testIdleIgnoresStrayEvents() {
        var m = SnapshotPauseStateMachine()
        m.handle(.displaySettled(needsRestore: true))
        m.handle(.restoreStarted)
        m.handle(.restoreFinished(success: true))
        XCTAssertEqual(m.state, .idle)
    }

    func testCallbackWhileAwaitingRestoreReentersChange() {
        var m = SnapshotPauseStateMachine()
        m.handle(.displayCallback)
        m.handle(.displaySettled(needsRestore: true))
        m.handle(.displayCallback)
        XCTAssertEqual(m.state, .changeInProgress)
    }

    func testGateRefusesWhilePausedWithReasonMessages() {
        var m = SnapshotPauseStateMachine()
        let l = DeskLookup(match: .knownDesk, layout: layout(["a", "b"]))
        XCTAssertEqual(SnapshotPolicy.decide(machine: m, lookup: l), .allowed)
        m.handle(.displayCallback)
        XCTAssertEqual(SnapshotPolicy.decide(machine: m, lookup: l), .refused(.displayChangeInProgress))
        m.handle(.displaySettled(needsRestore: true))
        XCTAssertEqual(SnapshotPolicy.decide(machine: m, lookup: l), .refused(.awaitingRestore))
        m.handle(.restoreStarted)
        XCTAssertEqual(SnapshotPolicy.decide(machine: m, lookup: l), .refused(.restoring))
        for r in [SnapshotRefusal.displayChangeInProgress, .awaitingRestore, .restoring, .dockedSetAbsent,
                  .accessibilityMissing, .layoutUnverified] {
            XCTAssertFalse(r.message.isEmpty)
        }
    }

    /// Updated for per-desk layouts (per-desk layouts): only a strict subset of a learned desk refuses; a
    /// superset or an unrelated set is a new desk and is allowed (it used to refuse).
    func testGateRefusesOnlyStrictSubsetOfKnownDesk() {
        let m = SnapshotPauseStateMachine()
        let desk = [DeskKey.make(for: layout(["a", "b", "c"]))!: layout(["a", "b", "c"])]
        func decide(_ live: [String]) -> SnapshotGateDecision {
            SnapshotPolicy.decide(machine: m, lookup: DeskLookup.resolve(live: layout(live), layouts: desk))
        }
        XCTAssertEqual(decide(["a"]), .refused(.dockedSetAbsent))
        XCTAssertEqual(decide(["a", "b", "c"]), .allowed)
        XCTAssertEqual(decide(["a", "b", "c", "d"]), .allowed)  // superset: new desk
        XCTAssertEqual(decide(["x", "y"]), .allowed)            // another desk
        XCTAssertEqual(SnapshotPolicy.decide(machine: m, lookup: .newDesk), .allowed)  // nothing learned
    }

    // MARK: - SnapshotGate (the write barrier the machine labels)

    func testGateCloseBumpsEpochAndInvalidatesTokens() throws {
        let gate = SnapshotGate()
        let token = try XCTUnwrap(gate.token())
        XCTAssertTrue(token.isValid)
        let epoch = gate.closeForDisplayChange()
        XCTAssertEqual(epoch, 1)
        XCTAssertNil(gate.token(), "no token while closed")
        XCTAssertFalse(token.isValid)
        XCTAssertEqual(gate.status, SnapshotGate.Status(isOpen: false, epoch: 1, reason: .displayChangeInProgress))
        XCTAssertEqual(gate.closeForDisplayChange(), 2, "every raw callback bumps the epoch")
    }

    func testGateReopensOnlyAtTheNewestEpoch() throws {
        let gate = SnapshotGate()
        let first = gate.closeForDisplayChange()
        let second = gate.closeForDisplayChange()  // a callback the reopener has not ingested yet
        XCTAssertFalse(gate.reopen(ifEpoch: first))
        XCTAssertFalse(gate.isOpen)
        XCTAssertTrue(gate.reopen(ifEpoch: second))
        XCTAssertEqual(gate.status, SnapshotGate.Status(isOpen: true, epoch: second, reason: nil))
        let stale = try XCTUnwrap(gate.token())
        gate.closeForDisplayChange()
        gate.reopen(ifEpoch: gate.epoch)
        XCTAssertFalse(stale.isValid, "a reopen at a newer epoch never revives an older token")
    }

    func testGateRelabelOnlyWhileClosedAndCommitIsAtomicWithCheck() throws {
        let gate = SnapshotGate()
        gate.relabel(.restoring)
        XCTAssertNil(gate.status.reason, "relabel never closes an open gate")
        let token = try XCTUnwrap(gate.token())
        var writes = 0
        XCTAssertTrue(token.commitIfValid { writes += 1 })
        gate.closeForDisplayChange()
        gate.relabel(.awaitingRestore)
        XCTAssertEqual(gate.refusal, .awaitingRestore)
        XCTAssertFalse(token.commitIfValid { writes += 1 })
        XCTAssertEqual(writes, 1)
    }
}

// MARK: - SnapshotGate holds

/// Readiness the test flips. Lock-protected so the observer's task can read it.
final class FakeSessionReadiness: SessionReadinessProbing, Sendable {
    private let ready: Mutex<Bool>
    init(ready: Bool) { self.ready = Mutex(ready) }
    func set(_ value: Bool) { ready.withLock { $0 = value } }
    func isSessionReady() async -> Bool { ready.withLock { $0 } }
}

final class SnapshotGateHoldTests: XCTestCase {
    func testHoldBumpsEpochAndBlocksTokensUntilCleared() throws {
        let gate = SnapshotGate()
        let inFlight = try XCTUnwrap(gate.token())
        XCTAssertTrue(gate.setHold(.screensAsleep))
        XCTAssertEqual(gate.epoch, 1, "setting a hold bumps the epoch")
        XCTAssertTrue(gate.isOpen, "a hold is not a display close")
        XCTAssertFalse(gate.acceptsSnapshots)
        XCTAssertNil(gate.token())
        XCTAssertFalse(inFlight.isValid, "an in-flight capture is discarded")
        XCTAssertEqual(gate.refusal, .screensAsleep)

        XCTAssertTrue(gate.clearHold(.screensAsleep))
        XCTAssertFalse(inFlight.isValid, "clearing never revives an older token")
        XCTAssertNotNil(gate.token())
        XCTAssertEqual(gate.epoch, 1, "clearing a hold never moves the epoch")
    }

    func testClearingAHoldNeverReopensADisplayChangeClose() {
        let gate = SnapshotGate()
        gate.setHold(.screensAsleep)
        let close = gate.closeForDisplayChange()
        gate.clearHold(.screensAsleep)
        XCTAssertFalse(gate.isOpen)
        XCTAssertNil(gate.token())
        XCTAssertEqual(gate.refusal, .displayChangeInProgress, "a display close wins over a hold")
        XCTAssertTrue(gate.reopen(ifEpoch: close))
        XCTAssertNotNil(gate.token())
    }

    /// A hold set while closed bumps the epoch but must not wedge the controller's reopen at the epoch
    /// it ingested; writes stay blocked until the hold clears.
    func testHoldWhileClosedDoesNotBlockReopenAtIngestedEpoch() {
        let gate = SnapshotGate()
        let ingested = gate.closeForDisplayChange()
        gate.setHold(.screensAsleep)
        XCTAssertTrue(gate.reopen(ifEpoch: ingested))
        XCTAssertTrue(gate.isOpen)
        XCTAssertNil(gate.token(), "still held")
        gate.clearHold(.screensAsleep)
        XCTAssertNotNil(gate.token())
    }

    func testNewerDisplayCallbackStillRefusesReopenWithHoldsInterleaved() {
        let gate = SnapshotGate()
        let first = gate.closeForDisplayChange()
        gate.setHold(.screensAsleep)
        let second = gate.closeForDisplayChange()
        gate.clearHold(.screensAsleep)
        XCTAssertFalse(gate.reopen(ifEpoch: first), "a callback after the ingested one keeps it closed")
        XCTAssertTrue(gate.reopen(ifEpoch: second))
    }

    func testHoldDiscardsInFlightStoreWriteAndLearn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GateHold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = SnapshotGate()
        let token = try XCTUnwrap(gate.token())
        gate.setHold(.screensAsleep)
        let config = DisplayConfigSnapshot(fingerprint: "k", displayConfigName: "t", displays: [],
                                           lastSnapshotDate: Date(), windows: [])
        let outcome = try await SnapshotStore(directory: dir).save(config, key: "k", ifGate: token)
        XCTAssertEqual(outcome, .discardedGateClosed)
        let learned = await LearnedLayoutStore().learn(MonitorLayout(origins: ["a": .init(x: 0, y: 0)]), ifGate: token)
        XCTAssertFalse(learned)
    }

    func testScheduledTickWhileHeldRecordsSkipAndManualSaveIsRefused() async {
        let diag = RecordingDiagnostics()
        let gate = SnapshotGate()
        let coord = SnapshotCoordinator(capturer: HoldCountingCapturer(), gate: gate,
                                        liveLayout: { MonitorLayout(origins: [:]) }, diagnostics: diag)
        gate.setHold(.screensAsleep)
        await coord.runScheduledSnapshot()
        let manual = await coord.saveManually()
        XCTAssertEqual(manual, .refused(message: SnapshotRefusal.screensAsleep.message))
        XCTAssertEqual(diag.events.map(\.name), ["snapshot-skipped", "snapshot-refused"])
        XCTAssertEqual(diag.events.first?.fields["refusal"], .string("screens-asleep"))

        gate.clearHold(.screensAsleep)
        await coord.runScheduledSnapshot()
        XCTAssertEqual(diag.events.last?.name, "snapshot-written")
    }
}

private struct HoldCountingCapturer: SnapshotCapturing {
    func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult {
        SnapshotCaptureResult(reason: reason, outcome: .written, layout: MonitorLayout(origins: [:]),
                              configKey: "k", windowCount: 1)
    }
}

// MARK: - SystemWakeObserver hold

final class SystemWakeObserverHoldTests: XCTestCase {
    private func observer(gate: SnapshotGate, readiness: FakeSessionReadiness, clock: TestClock,
                          diagnostics: RecordingDiagnostics = RecordingDiagnostics(),
                          schedule: SessionReadiness.Schedule = .standard) -> SystemWakeObserver {
        SystemWakeObserver(now: { Date(timeIntervalSince1970: 1_000_000) }, diagnostics: diagnostics,
                           gate: gate, readiness: readiness, clock: clock, schedule: schedule)
    }

    func testScreensSleepSetsHoldAndWakeClearsItOnceReady() async {
        let gate = SnapshotGate()
        let readiness = FakeSessionReadiness(ready: false)
        let clock = TestClock()
        let diag = RecordingDiagnostics()
        let wake = observer(gate: gate, readiness: readiness, clock: clock, diagnostics: diag)

        wake.note(.screensSleep)
        XCTAssertEqual(gate.holds, [.screensAsleep])
        XCTAssertNil(gate.token())

        wake.note(.screensWake)
        await clock.waitForSleeper(deadline: .seconds(1))
        XCTAssertEqual(gate.holds, [.screensAsleep], "still at the lock screen: hold stays")
        readiness.set(true)
        await clock.advance(by: .seconds(1))
        await wake.waitForResume()
        XCTAssertTrue(gate.holds.isEmpty)
        XCTAssertNotNil(gate.token())
        let names = diag.events.map(\.name)
        XCTAssertEqual(names, ["screens-sleep", "snapshot-hold-set", "screens-wake", "snapshot-hold-cleared"])
        XCTAssertEqual(diag.events.last?.fields["result"], .string("ready"))
    }

    func testHoldClearsAfterTheBoundEvenIfNeverReady() async {
        let gate = SnapshotGate()
        let clock = TestClock()
        let schedule = SessionReadiness.Schedule(delays: [.seconds(1)], bound: .seconds(2))
        let diag = RecordingDiagnostics()
        let wake = observer(gate: gate, readiness: FakeSessionReadiness(ready: false), clock: clock,
                            diagnostics: diag, schedule: schedule)
        wake.note(.screensSleep)
        wake.note(.screensWake)
        await clock.waitForSleeper(deadline: .seconds(1))
        await clock.advance(by: .seconds(1))
        await clock.waitForSleeper(deadline: .seconds(2))
        await clock.advance(by: .seconds(1))
        await wake.waitForResume()
        XCTAssertTrue(gate.holds.isEmpty)
        XCTAssertEqual(diag.events.last?.fields["result"], .string("bounded"))
    }

    func testWakeClearingTheHoldNeverReopensADisplayClose() async {
        let gate = SnapshotGate()
        let wake = observer(gate: gate, readiness: FakeSessionReadiness(ready: true), clock: TestClock())
        wake.note(.screensSleep)
        gate.closeForDisplayChange()
        wake.note(.screensWake)
        await wake.waitForResume()
        XCTAssertTrue(gate.holds.isEmpty)
        XCTAssertFalse(gate.isOpen, "only AutomationController reopens a display close")
    }

    /// A sleep after the wake (before readiness passed) keeps the new hold: the old check never clears it.
    func testSleepDuringReadinessCheckKeepsTheNewHold() async {
        let gate = SnapshotGate()
        let readiness = FakeSessionReadiness(ready: false)
        let clock = TestClock()
        let wake = observer(gate: gate, readiness: readiness, clock: clock)
        wake.note(.screensSleep)
        wake.note(.screensWake)
        await clock.waitForSleeper(deadline: .seconds(1))
        wake.note(.screensSleep)
        readiness.set(true)
        await clock.advance(by: .seconds(1))
        await wake.waitForResume()
        XCTAssertEqual(gate.holds, [.screensAsleep])
    }

    func testLockHintsAreAdditiveOnly() async {
        let gate = SnapshotGate()
        let readiness = FakeSessionReadiness(ready: false)
        let clock = TestClock()
        let wake = observer(gate: gate, readiness: readiness, clock: clock)
        wake.note(.sessionLocked)
        XCTAssertEqual(gate.holds, [.screensAsleep], "a lock sets the hold earlier")
        wake.note(.sessionUnlocked)
        await clock.waitForSleeper(deadline: .seconds(1))
        XCTAssertEqual(gate.holds, [.screensAsleep], "an unlock alone never clears it")
        readiness.set(true)
        await clock.advance(by: .seconds(1))
        await wake.waitForResume()
        XCTAssertTrue(gate.holds.isEmpty)
    }
}

// MARK: - System wake with the screens still asleep (review advisory 1)

extension SystemWakeObserverHoldTests {
    /// A system wake (or an unlock hint) while the screens stay asleep never starts the bounded check,
    /// so the hold outlives the bound. Only screensDidWake starts it; the hold then clears once ready.
    func testSystemWakeWithScreensAsleepKeepsTheHoldPastTheBound() async {
        let gate = SnapshotGate()
        let readiness = FakeSessionReadiness(ready: false)
        let clock = TestClock()
        let schedule = SessionReadiness.Schedule(delays: [.seconds(1)], bound: .seconds(2))
        let wake = observer(gate: gate, readiness: readiness, clock: clock, schedule: schedule)

        wake.note(.screensSleep)
        wake.note(.systemWake)
        wake.note(.sessionUnlocked)
        await wake.waitForResume()
        await clock.advance(by: .seconds(5))
        await wake.waitForResume()
        XCTAssertEqual(gate.holds, [.screensAsleep], "screens still asleep: the bound never started")
        XCTAssertNil(gate.token())

        wake.note(.screensWake)
        await clock.waitForSleeper(deadline: .seconds(6))
        XCTAssertEqual(gate.holds, [.screensAsleep], "screens awake but the session is not ready yet")
        readiness.set(true)
        await clock.advance(by: .seconds(1))
        await wake.waitForResume()
        XCTAssertTrue(gate.holds.isEmpty)
        XCTAssertNotNil(gate.token())
    }
}
