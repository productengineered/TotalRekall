import CoreGraphics
import Synchronization
import XCTest
@testable import TotalRekall

private actor FakePause: SnapshotPauseControlling {
    private(set) var scheduledSnapshots = 0
    /// Learned layouts by desk key, resolved with the production lookup rules.
    private(set) var layouts: [String: MonitorLayout] = [:]
    init(learned: MonitorLayout) { self.init(desks: [learned]) }
    init(desks: [MonitorLayout]) {
        for desk in desks {
            if let key = DeskKey.make(for: desk) { layouts[key] = desk }
        }
    }

    func deskLookup(live: MonitorLayout) -> DeskLookup {
        DeskLookup.resolve(live: live, layouts: layouts)
    }
    func runScheduledSnapshot() { scheduledSnapshots += 1 }
}

/// Records whether the gate was open at every restore entry; can block inside the restore.
private actor FakeRestorer: AutoRestoring {
    private let gate: SnapshotGate
    private(set) var restoreCalls = 0
    private(set) var fixCalls = 0
    private(set) var gateOpenAtEntry: [Bool] = []
    private var release: CheckedContinuation<Void, Never>?
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    var blockRestore = false
    var restoreOutcome: RestoreOutcome = .restored(RestoreSummary(results: [], date: Date(timeIntervalSince1970: 0)))
    var fixOutcome: RestoreOutcome = .monitorsFixed(.verified, date: Date())

    init(gate: SnapshotGate) { self.gate = gate }

    func setBlock(_ value: Bool) { blockRestore = value }
    func setOutcome(_ outcome: RestoreOutcome) { restoreOutcome = outcome }
    func unblock() { release?.resume(); release = nil }

    /// Suspends until `count` restores have been entered.
    func waitUntilEntered(_ count: Int) async {
        if restoreCalls >= count { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }

    func restoreNow() async -> RestoreOutcome {
        restoreCalls += 1
        gateOpenAtEntry.append(gate.isOpen)
        let ready = entryWaiters.filter { $0.count <= restoreCalls }
        entryWaiters.removeAll { $0.count <= restoreCalls }
        ready.forEach { $0.continuation.resume() }
        if blockRestore {
            await withCheckedContinuation { release = $0 }
        }
        return restoreOutcome
    }

    func fixMonitors() async -> RestoreOutcome { fixCalls += 1; return fixOutcome }
}

/// Records each status call together with whether the gate was open at that instant.
private actor FakeStatus: AutomationStatusReporting {
    private let gate: SnapshotGate
    private(set) var events: [String] = []
    private(set) var gateOpenObserved: [Bool] = []
    init(gate: SnapshotGate) { self.gate = gate }

    func automationDidBegin() { events.append("begin"); gateOpenObserved.append(gate.isOpen) }
    func automationDidFinish(outcome: RestoreOutcome?) {
        events.append(outcome == nil ? "finish:nil" : "finish:outcome")
        gateOpenObserved.append(gate.isOpen)
    }
}

private actor CountingCapturer: SnapshotCapturing {
    private(set) var captures = 0
    func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult {
        captures += 1
        return SnapshotCaptureResult(reason: reason, outcome: .written, layout: MonitorLayout(origins: [:]),
                                     configKey: "k", windowCount: 1)
    }
}

private final class FakeTrust: AccessibilityTrustChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var trusted: Bool
    init(_ trusted: Bool) { self.trusted = trusted }
    func set(_ value: Bool) { lock.lock(); trusted = value; lock.unlock() }
    func isProcessTrusted() -> Bool { lock.lock(); defer { lock.unlock() }; return trusted }
}

private final class LiveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MonitorLayout
    init(_ value: MonitorLayout) { self.value = value }
    func get() -> MonitorLayout { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: MonitorLayout) { lock.lock(); value = v; lock.unlock() }
}

final class AutomationControllerTests: XCTestCase {
    private func layout(_ serials: [String]) -> MonitorLayout {
        MonitorLayout(origins: Dictionary(uniqueKeysWithValues: serials.enumerated().map { ($0.element, .init(x: $0.offset * 1000, y: 0)) }))
    }

    private struct Rig {
        let controller: AutomationController
        let gate: SnapshotGate
        let pause: FakePause
        let restorer: FakeRestorer
        let status: FakeStatus
        let clock: TestClock
        let live: LiveBox
        let trust: FakeTrust

        /// A raw callback (closes the gate synchronously) followed by its settled event.
        func fire() async {
            let epoch = gate.closeForDisplayChange()
            await controller.receive(DisplayChangeEvent(added: [1], rawEventCount: 1, throughEpoch: epoch))
        }
    }

    /// `immediate` clocks run every sleep at once (cycle runs straight to completion).
    private func makeRig(learned: [String] = ["A", "B"], live: [String] = ["A", "B"], trusted: Bool = true,
                         immediate: Bool = true, otherDesks: [[String]] = []) -> Rig {
        let gate = SnapshotGate()
        let pause = FakePause(desks: ([learned] + otherDesks).map { layout($0) })
        let restorer = FakeRestorer(gate: gate)
        let status = FakeStatus(gate: gate)
        let clock = TestClock(immediate: immediate)
        let liveBox = LiveBox(layout(live))
        let trust = FakeTrust(trusted)
        let (stream, _) = AsyncStream.makeStream(of: DisplayChangeEvent.self)
        let controller = AutomationController(
            events: stream, gate: gate, pause: pause, restorer: restorer, trust: trust,
            status: status, liveLayout: { liveBox.get() }, clock: clock
        )
        return Rig(controller: controller, gate: gate, pause: pause, restorer: restorer, status: status,
                   clock: clock, live: liveBox, trust: trust)
    }

    func testChangeThenSettleRestoreAndResume() async {
        let rig = makeRig()
        await rig.fire()
        XCTAssertFalse(rig.gate.isOpen)
        await rig.controller.waitUntilIdle()

        let restoreCalls = await rig.restorer.restoreCalls
        let gateDuringRestore = await rig.restorer.gateOpenAtEntry
        let status = await rig.status.events
        let state = await rig.controller.pauseState
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertEqual(gateDuringRestore, [false])
        XCTAssertEqual(status, ["begin", "finish:outcome"])
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(rig.gate.isOpen, "the controller reopens the gate after the restore")
    }

    func testWaitsRestoreDelayBeforeRestoring() async {
        let rig = makeRig(immediate: false)
        await rig.fire()
        await rig.clock.waitForSleeper(deadline: .seconds(3))
        await rig.clock.advance(by: .seconds(2))
        let early = await rig.restorer.restoreCalls
        XCTAssertEqual(early, 0)
        await rig.clock.advance(by: .seconds(1))
        await rig.clock.waitForSleeper(deadline: .seconds(4))  // stability poll
        await rig.clock.advance(by: .seconds(1))
        await rig.controller.waitUntilIdle()
        let late = await rig.restorer.restoreCalls
        XCTAssertEqual(late, 1)
    }

    func testUndockedNeverRestoresAndKeepsGateClosed() async {
        let rig = makeRig(live: ["A"])
        await rig.fire()
        await rig.controller.waitUntilIdle()

        let restoreCalls = await rig.restorer.restoreCalls
        let status = await rig.status.events
        XCTAssertEqual(restoreCalls, 0)
        XCTAssertEqual(status, ["begin", "finish:nil"])
        XCTAssertEqual(rig.gate.status.isOpen, false)
        XCTAssertEqual(rig.gate.status.reason, .dockedSetAbsent)
    }

    func testRedockAfterAbsentTriggersRestore() async {
        let rig = makeRig(live: ["A"])
        await rig.fire()
        await rig.controller.waitUntilIdle()
        rig.live.set(layout(["A", "B"]))
        await rig.fire()
        await rig.controller.waitUntilIdle()
        let restoreCalls = await rig.restorer.restoreCalls
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertTrue(rig.gate.isOpen)
    }

    /// Fix 4: with Accessibility missing nothing is automated AND the gate stays closed, so a
    /// possibly swapped layout is never snapshotted or learned.
    func testAccessibilityMissingIsNoOp() async {
        let rig = makeRig(trusted: false)
        await rig.fire()
        await rig.controller.waitUntilIdle()
        let restoreCalls = await rig.restorer.restoreCalls
        let status = await rig.status.events
        XCTAssertEqual(restoreCalls, 0)
        XCTAssertTrue(status.isEmpty)
        XCTAssertFalse(rig.gate.isOpen)
        XCTAssertEqual(rig.gate.status.reason, .accessibilityMissing)
    }

    func testAccessibilityReturningRunsCycleThenReopens() async {
        let rig = makeRig(trusted: false)
        await rig.fire()
        await rig.controller.waitUntilIdle()
        await rig.controller.accessibilityChanged(trusted: false)  // still missing: nothing happens
        await rig.controller.waitUntilIdle()
        XCTAssertFalse(rig.gate.isOpen)

        rig.trust.set(true)
        await rig.controller.accessibilityChanged(trusted: true)
        await rig.controller.waitUntilIdle()
        let restoreCalls = await rig.restorer.restoreCalls
        let gateDuringRestore = await rig.restorer.gateOpenAtEntry
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertEqual(gateDuringRestore, [false])
        XCTAssertTrue(rig.gate.isOpen)
    }

    /// Fix 3: a change during the restore queues exactly one follow-up and the gate is never open
    /// between the two cycles.
    func testBurstDuringRestoreQueuesExactlyOneFollowUpWithGateClosedBetween() async {
        let rig = makeRig()
        await rig.restorer.setBlock(true)
        await rig.fire()
        await rig.restorer.waitUntilEntered(1)
        let duringState = await rig.controller.pauseState
        XCTAssertEqual(duringState, .restoring)

        for _ in 0..<5 { await rig.fire() }
        let lastEpoch = rig.gate.epoch
        await rig.restorer.setBlock(false)
        await rig.restorer.unblock()
        await rig.controller.waitUntilIdle()

        let restoreCalls = await rig.restorer.restoreCalls
        XCTAssertEqual(restoreCalls, 2)  // original + exactly one follow-up
        let atEntry = await rig.restorer.gateOpenAtEntry
        XCTAssertEqual(atEntry, [false, false])
        let observed = await rig.status.gateOpenObserved
        XCTAssertEqual(observed, [false, false, false, false], "closed at every hook of both cycles")
        let status = await rig.status.events
        XCTAssertEqual(status, ["begin", "finish:outcome", "begin", "finish:outcome"])
        XCTAssertEqual(rig.gate.status, SnapshotGate.Status(isOpen: true, epoch: lastEpoch, reason: nil))
        let state = await rig.controller.pauseState
        XCTAssertEqual(state, .idle)
    }

    /// A raw callback whose event is still in the debounce when the restore ends keeps the gate
    /// closed; its event later runs the next cycle, which reopens it.
    func testCallbackStillDebouncingKeepsGateClosedAfterRestore() async {
        let rig = makeRig()
        await rig.restorer.setBlock(true)
        await rig.fire()
        await rig.restorer.waitUntilEntered(1)
        let pendingEpoch = rig.gate.closeForDisplayChange()  // raw only; event not yet settled
        await rig.restorer.setBlock(false)
        await rig.restorer.unblock()
        await rig.controller.waitUntilIdle()
        XCTAssertFalse(rig.gate.isOpen)

        await rig.controller.receive(DisplayChangeEvent(moved: [1], rawEventCount: 1, throughEpoch: pendingEpoch))
        await rig.controller.waitUntilIdle()
        let restoreCalls = await rig.restorer.restoreCalls
        XCTAssertEqual(restoreCalls, 2)
        XCTAssertTrue(rig.gate.isOpen)
    }

    func testEventBeforeRestoreRestartsSettleWait() async {
        let rig = makeRig(immediate: false)
        await rig.fire()
        await rig.clock.waitForSleeper(deadline: .seconds(3))
        await rig.fire()  // layout moved again during the delay
        await rig.clock.advance(by: .seconds(3))
        await rig.clock.waitForSleeper(deadline: .seconds(6))  // a fresh restore delay
        let early = await rig.restorer.restoreCalls
        XCTAssertEqual(early, 0)
        await rig.clock.advance(by: .seconds(3))
        await rig.clock.waitForSleeper(deadline: .seconds(7))
        await rig.clock.advance(by: .seconds(1))
        await rig.controller.waitUntilIdle()
        let restoreCalls = await rig.restorer.restoreCalls
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertTrue(rig.gate.isOpen)
    }

    /// Nothing to restore: the gate reopens only when the live layout matches the learned one.
    func testNoSnapshotReopensOnlyWhenLayoutVerified() async {
        let swapped = MonitorLayout(origins: ["A": .init(x: 1000, y: 0), "B": .init(x: 0, y: 0)])
        struct Case { let live: MonitorLayout?; let open: Bool; let reason: SnapshotRefusal? }
        let cases = [
            Case(live: nil, open: true, reason: nil),                        // live == learned
            Case(live: swapped, open: false, reason: .layoutUnverified)      // same serials, swapped origins
        ]
        for testCase in cases {
            let rig = makeRig()
            if let live = testCase.live { rig.live.set(live) }
            await rig.restorer.setOutcome(.noSnapshot)
            await rig.fire()
            await rig.controller.waitUntilIdle()
            XCTAssertEqual(rig.gate.isOpen, testCase.open)
            XCTAssertEqual(rig.gate.status.reason, testCase.reason)
        }
    }

    // MARK: - Per-desk learned layouts (per-desk layouts)

    /// RCA (1): launched undocked (learned {builtin}), then docked to a set with no snapshot: a new
    /// desk is a first run, so the gate reopens instead of holding layoutUnverified.
    func testNewDeskWithNoSnapshotReopensGate() async {
        let rig = makeRig(learned: ["builtin"], live: ["builtin", "X", "Y"])
        await rig.restorer.setOutcome(.noSnapshot)
        await rig.fire()
        await rig.controller.waitUntilIdle()
        XCTAssertTrue(rig.gate.isOpen)
        XCTAssertNil(rig.gate.status.reason)
    }

    /// RCA (2): learned desk 1, docked at desk 2: the cycle waits for nothing, restores, and reopens.
    func testSecondDeskIsNotHeldAsAbsent() async {
        let rig = makeRig(learned: ["A", "B"], live: ["C", "D"])
        await rig.fire()
        await rig.controller.waitUntilIdle()
        let restoreCalls = await rig.restorer.restoreCalls
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertTrue(rig.gate.isOpen)
    }

    /// RCA (3) and C2 (11): back at desk 1 after desk 2, the swap check runs against desk 1's own
    /// layout: a swapped desk 1 is held (not learned), and desk 2 verifies against desk 2's layout.
    func testReturnToKnownDeskChecksItsOwnLayout() async {
        let rig = makeRig(learned: ["A", "B"], live: ["C", "D"], otherDesks: [["C", "D"]])
        await rig.restorer.setOutcome(.noSnapshot)
        await rig.fire()
        await rig.controller.waitUntilIdle()
        XCTAssertTrue(rig.gate.isOpen, "desk 2 matches its own layout")

        rig.live.set(MonitorLayout(origins: ["A": .init(x: 1000, y: 0), "B": .init(x: 0, y: 0)]))
        await rig.fire()
        await rig.controller.waitUntilIdle()
        XCTAssertFalse(rig.gate.isOpen)
        XCTAssertEqual(rig.gate.status.reason, .layoutUnverified)
    }

    /// C2 (9): a strict subset of a known desk waits, then holds; it is never treated as a new desk.
    func testStrictSubsetOfKnownDeskHolds() async {
        let rig = makeRig(learned: ["A", "B", "C"], live: ["A", "B"])
        await rig.restorer.setOutcome(.noSnapshot)
        await rig.fire()
        await rig.controller.waitUntilIdle()
        let restoreCalls = await rig.restorer.restoreCalls
        XCTAssertEqual(restoreCalls, 0)
        XCTAssertFalse(rig.gate.isOpen)
        XCTAssertEqual(rig.gate.status.reason, .dockedSetAbsent)
    }

    /// C2 (10): a superset of a known desk (a projector added) is a new desk, not a hold.
    func testSupersetOfKnownDeskIsNewDesk() async {
        let rig = makeRig(learned: ["A", "B"], live: ["A", "B", "P"])
        await rig.restorer.setOutcome(.noSnapshot)
        await rig.fire()
        await rig.controller.waitUntilIdle()
        XCTAssertTrue(rig.gate.isOpen)
    }

    /// RCA (6): learned with the lid open {builtin, X, Y}, lid closed {X, Y}: same desk, not absent.
    func testClamshellIsTheSameDesk() async {
        let rig = makeRig(learned: ["builtin", "X", "Y"], live: [])
        rig.live.set(MonitorLayout(origins: ["X": .init(x: 1000, y: 0), "Y": .init(x: 2000, y: 0)]))
        await rig.restorer.setOutcome(.noSnapshot)
        await rig.fire()
        await rig.controller.waitUntilIdle()
        XCTAssertTrue(rig.gate.isOpen)
        XCTAssertNil(rig.gate.status.reason)
    }

    /// Fix 2: DisplayMonitor settles and emits the event, but the gate stays closed until the
    /// controller has ingested it and finished the cycle. A snapshot attempted in that window (after
    /// settle, before ingest) is refused.
    func testNoOpenInstantBetweenSettleAndControllerIngest() async throws {
        let gate = SnapshotGate()
        let monitorClock = TestClock()
        let window = Duration.milliseconds(1500)
        let monitor = DisplayMonitor(debounce: window, clock: monitorClock, snapshotGate: gate)
        var settled = monitor.events.makeAsyncIterator()
        await monitor.startProcessing()

        let capturer = CountingCapturer()
        let snapshots = SnapshotCoordinator(capturer: capturer, gate: gate, liveLayout: { MonitorLayout(origins: [:]) })
        let restorer = FakeRestorer(gate: gate)
        let pause = FakePause(learned: MonitorLayout(origins: [:]))
        let (stream, _) = AsyncStream.makeStream(of: DisplayChangeEvent.self)
        let controller = AutomationController(
            events: stream, gate: gate, pause: pause, restorer: restorer, trust: FakeTrust(true),
            status: FakeStatus(gate: gate), liveLayout: { MonitorLayout(origins: [:]) },
            clock: TestClock(immediate: true)
        )

        XCTAssertTrue(monitor.receive(RawDisplayEvent(displayID: 1, flags: CGDisplayChangeSummaryFlags.addFlag.rawValue,
                                                      vendorID: 0x10AC, source: .reconfigurationCallback)))
        XCTAssertFalse(gate.isOpen, "closed by the callback itself")
        await monitorClock.waitForSleeper(deadline: window)
        await monitorClock.advance(by: window)
        let next = await settled.next()
        let event = try XCTUnwrap(next)
        XCTAssertFalse(monitor.isChangeInProgress, "debounce settled")
        XCTAssertEqual(event.throughEpoch, gate.epoch)

        // Settled but not yet ingested by the controller: still closed, snapshots refused.
        XCTAssertFalse(gate.isOpen)
        let manual = await snapshots.saveManually()
        XCTAssertEqual(manual, .refused(message: SnapshotRefusal.displayChangeInProgress.message))
        await snapshots.runScheduledSnapshot()
        let captures = await capturer.captures
        XCTAssertEqual(captures, 0)

        await controller.receive(event)
        await controller.waitUntilIdle()
        XCTAssertTrue(gate.isOpen, "only the controller reopens, after the restore")
        await monitor.stop()
    }

    func testStartRunsLaunchCheckThenSchedulerSnapshot() async {
        let rig = makeRig(immediate: false)
        await rig.controller.start()
        await rig.clock.waitForSleeper(deadline: .seconds(600))  // first tick done, next one armed
        let snapshots = await rig.pause.scheduledSnapshots
        let fixCalls = await rig.restorer.fixCalls
        XCTAssertEqual(snapshots, 1)
        XCTAssertEqual(fixCalls, 1)
        await rig.controller.stop()
    }

    func testLaunchCheckSkippedWithoutAccessibility() async {
        let rig = makeRig(trusted: false, immediate: false)
        await rig.controller.start()
        await rig.clock.waitForSleeper(deadline: .seconds(600))
        let snapshots = await rig.pause.scheduledSnapshots
        let fixCalls = await rig.restorer.fixCalls
        XCTAssertEqual(snapshots, 1)
        XCTAssertEqual(fixCalls, 0)
        await rig.controller.stop()
    }
}

// MARK: - Session hold

extension AutomationControllerTests {
    private struct SessionRig {
        let controller: AutomationController
        let gate: SnapshotGate
        let restorer: FakeRestorer
        let status: FakeStatus
        let clock: TestClock
        let readiness: FakeSessionReadiness

        func fire() async {
            let epoch = gate.closeForDisplayChange()
            await controller.receive(DisplayChangeEvent(added: [1], rawEventCount: 1, throughEpoch: epoch))
        }

        /// Restore delay (3 s) then one stability poll (1 s), starting at virtual time `start`.
        func settle(from start: Int) async {
            await clock.waitForSleeper(deadline: .seconds(start + 3))
            await clock.advance(by: .seconds(3))
            await clock.waitForSleeper(deadline: .seconds(start + 4))
            await clock.advance(by: .seconds(1))
        }
    }

    private func makeSessionRig(schedule: SessionReadiness.Schedule = .standard) -> SessionRig {
        let gate = SnapshotGate()
        let restorer = FakeRestorer(gate: gate)
        let status = FakeStatus(gate: gate)
        let clock = TestClock()
        let live = LiveBox(layout(["A", "B"]))
        let readiness = FakeSessionReadiness(ready: false)
        let (stream, _) = AsyncStream.makeStream(of: DisplayChangeEvent.self)
        let controller = AutomationController(
            events: stream, gate: gate, pause: FakePause(learned: layout(["A", "B"])), restorer: restorer,
            trust: FakeTrust(true), status: status, liveLayout: { live.get() }, clock: clock,
            diagnostics: RecordingDiagnostics(), sessionReadiness: readiness, sessionSchedule: schedule)
        return SessionRig(controller: controller, gate: gate, restorer: restorer, status: status, clock: clock,
                          readiness: readiness)
    }

    /// Screens wake at the lock screen: display callbacks arrive but other apps' windows cannot be read.
    /// The cycle holds with the gate closed (no restore, no tick can write), a further callback while
    /// still locked keeps it held, and once readiness passes the restore runs and the gate reopens.
    func testWakeWhileLockedHoldsCycleThenRestoresOnceSessionReady() async {
        let rig = makeSessionRig()
        await rig.fire()
        await rig.settle(from: 0)
        await rig.controller.waitUntilIdle()
        var restoreCalls = await rig.restorer.restoreCalls
        XCTAssertEqual(restoreCalls, 0)
        XCTAssertFalse(rig.gate.isOpen)
        XCTAssertEqual(rig.gate.status.reason, .sessionNotReady)
        XCTAssertNil(rig.gate.token(), "a scheduled tick during the hold writes nothing")
        let heldStatus = await rig.status.events
        XCTAssertEqual(heldStatus, ["begin", "finish:nil"], "no outcome, so no notification")

        await rig.fire()  // another callback while still locked
        await rig.settle(from: 4)
        await rig.controller.waitUntilIdle()
        restoreCalls = await rig.restorer.restoreCalls
        XCTAssertEqual(restoreCalls, 0)
        XCTAssertEqual(rig.gate.status.reason, .sessionNotReady)

        await rig.clock.waitForSleeper(deadline: .seconds(9))  // readiness re-check armed
        rig.readiness.set(true)
        await rig.clock.advance(by: .seconds(1))
        await rig.settle(from: 9)
        await rig.controller.waitUntilIdle()
        restoreCalls = await rig.restorer.restoreCalls
        let gateDuringRestore = await rig.restorer.gateOpenAtEntry
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertEqual(gateDuringRestore, [false])
        XCTAssertTrue(rig.gate.isOpen)
    }

    func testSessionWaitBoundRestoresAnywaySoTheGateCannotStayClosed() async {
        let rig = makeSessionRig(schedule: SessionReadiness.Schedule(delays: [.seconds(1)], bound: .seconds(1)))
        await rig.fire()
        await rig.settle(from: 0)
        await rig.controller.waitUntilIdle()
        await rig.clock.waitForSleeper(deadline: .seconds(5))
        await rig.clock.advance(by: .seconds(1))
        await rig.settle(from: 5)
        await rig.controller.waitUntilIdle()
        let restoreCalls = await rig.restorer.restoreCalls
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertTrue(rig.gate.isOpen)
    }

    func testSessionMayBeReadyResumesHeldCycleImmediately() async {
        let rig = makeSessionRig()
        await rig.fire()
        await rig.settle(from: 0)
        await rig.controller.waitUntilIdle()
        await rig.controller.sessionMayBeReady()  // still not ready: nothing happens
        var restoreCalls = await rig.restorer.restoreCalls
        XCTAssertEqual(restoreCalls, 0)

        rig.readiness.set(true)
        await rig.controller.sessionMayBeReady()
        await rig.settle(from: 4)
        await rig.controller.waitUntilIdle()
        restoreCalls = await rig.restorer.restoreCalls
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertTrue(rig.gate.isOpen)
    }
}

// MARK: - Quiet wake

/// Stands in for RestoreCoordinator's quiet decision: every window comes back already-correct with the
/// monitors already in order, so the received context alone decides (through the real QuietWakePolicy).
/// Counts the restore-log writes a non-quiet outcome would make.
private actor PolicyRestorer: AutoRestoring {
    private(set) var contexts: [CycleContext] = []
    private(set) var logWrites = 0
    private let snapshotID = UUID()
    /// Outcomes returned (in order) before the policy-driven behavior takes over.
    private var scripted: [RestoreOutcome]

    init(scripted: [RestoreOutcome] = []) { self.scripted = scripted }

    func restoreNow(context: CycleContext) async -> RestoreOutcome {
        contexts.append(context)
        if !scripted.isEmpty { return scripted.removeFirst() }
        let results = [RestoreWindowResult(snapshotID: snapshotID, windowID: 1, bundleID: "com.example",
                                           appName: "App", title: "t", status: .alreadyCorrect)]
        let summary = RestoreSummary(results: results, date: Date(timeIntervalSince1970: 50),
                                     monitorFix: .alreadyInOrder)
        let quiet = QuietWakePolicy.isQuiet(QuietWakePolicy.Input(
            trigger: context.trigger, eligibility: context.quietWake, fix: .alreadyInOrder,
            snapshotWindows: [.init(id: snapshotID, bundleID: "com.example")], ownBundleID: "own",
            results: results))
        if quiet { return .quietWake(summary) }
        logWrites += 1
        return .restored(summary)
    }
}

private struct FixedWake: WakeTracking {
    let trigger: CycleTrigger
    func triggerForDisplayChange() -> CycleTrigger { trigger }
}

private final class PostCountingCenter: UserNotificationCentering, Sendable {
    private let posts = Mutex(0)
    var posted: Int { posts.withLock { $0 } }
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func add(_ request: ProblemNotificationRequest) async throws { posts.withLock { $0 += 1 } }
}

extension AutomationControllerTests {
    @MainActor
    private struct QuietRig {
        let controller: AutomationController
        let gate: SnapshotGate
        let restorer: PolicyRestorer
        let status: NotifyingAutomationStatus
        let center: PostCountingCenter
        let viewModel: MenuBarViewModel
        let clock: TestClock
        let diagnostics: RecordingDiagnostics
        static let previous = RestoreResult.windows(restored: 2, total: 3, date: Date(timeIntervalSince1970: 1))

        /// A raw callback and its settled event; `added` marks a display added (a real dock change).
        func fire(added: Bool = false) async {
            let epoch = gate.closeForDisplayChange()
            await controller.receive(DisplayChangeEvent(added: added ? [1] : [], moved: added ? [] : [1],
                                                        rawEventCount: 1, throughEpoch: epoch))
        }

        func settle(from start: Int) async {
            await clock.waitForSleeper(deadline: .seconds(start + 3))
            await clock.advance(by: .seconds(3))
            await clock.waitForSleeper(deadline: .seconds(start + 4))
            await clock.advance(by: .seconds(1))
        }

        func finish() async {
            await controller.waitUntilIdle()
            await status.waitForNotifications()
        }

        func cycleFinishedOutcomes() -> [DiagnosticsValue?] {
            diagnostics.events.filter { $0.name == "cycle-finished" }.map { $0.fields["outcome"] }
        }
    }

    @MainActor
    private func makeQuietRig(trigger: CycleTrigger = .wake, readiness: FakeSessionReadiness? = nil,
                              schedule: SessionReadiness.Schedule = .standard,
                              scripted: [RestoreOutcome] = []) -> QuietRig {
        let gate = SnapshotGate()
        let restorer = PolicyRestorer(scripted: scripted)
        let viewModel = MenuBarViewModel()
        viewModel.lastResult = QuietRig.previous
        let center = PostCountingCenter()
        let diagnostics = RecordingDiagnostics()
        let status = NotifyingAutomationStatus(inner: MenuAutomationStatus(viewModel: viewModel),
                                               notifier: ProblemNotifier(center: center, diagnostics: diagnostics))
        let clock = TestClock(immediate: readiness == nil)
        let live = LiveBox(layout(["A", "B"]))
        let (stream, _) = AsyncStream.makeStream(of: DisplayChangeEvent.self)
        let controller = AutomationController(
            events: stream, gate: gate, pause: FakePause(learned: layout(["A", "B"])), restorer: restorer,
            trust: FakeTrust(true), status: status, liveLayout: { live.get() }, clock: clock,
            wake: FixedWake(trigger: trigger), diagnostics: diagnostics, sessionReadiness: readiness,
            sessionSchedule: schedule)
        return QuietRig(controller: controller, gate: gate, restorer: restorer, status: status, center: center,
                        viewModel: viewModel, clock: clock, diagnostics: diagnostics)
    }

    /// AC1: Last restore, its detail and the icon are as before, no log write, no notification, the gate
    /// reopens, and cycle-finished reads outcome=quiet with restored/total.
    @MainActor
    func testQuietWakeLeavesLastRestoreAndLogUntouched() async {
        let rig = makeQuietRig()
        rig.viewModel.state = .attention
        await rig.fire()
        await rig.finish()

        let contexts = await rig.restorer.contexts
        XCTAssertEqual(contexts.first?.quietWake,
                       QuietWakeEligibility(displaysAddedOrRemoved: false, resumedByHoldBound: false))
        let logWrites = await rig.restorer.logWrites
        XCTAssertEqual(logWrites, 0)
        XCTAssertEqual(rig.viewModel.lastResult, QuietRig.previous)
        XCTAssertNil(rig.viewModel.lastRestoreDetail)
        XCTAssertEqual(rig.viewModel.state, .attention, "the icon is what it was before the cycle")
        XCTAssertEqual(rig.center.posted, 0)
        XCTAssertTrue(rig.gate.isOpen)
        let finished = rig.diagnostics.events.first { $0.name == "cycle-finished" }
        XCTAssertEqual(finished?.cycleID, contexts.first?.cycleID)
        XCTAssertEqual(finished?.fields["outcome"], .string("quiet"))
        XCTAssertEqual(finished?.fields["restored"], .int(1))
        XCTAssertEqual(finished?.fields["total"], .int(1))
        XCTAssertEqual(finished?.fields["needsAttention"], .bool(false))
    }

    /// AC2/AC8: a display-change cycle, and a wake whose events added a display, restore normally even
    /// with every window already-correct.
    @MainActor
    func testDisplayChangeAllAlreadyCorrectStillUpdatesLastRestore() async {
        for (trigger, added) in [(CycleTrigger.displayChange, true), (.displayChange, false), (.wake, true)] {
            let rig = makeQuietRig(trigger: trigger)
            await rig.fire(added: added)
            await rig.finish()
            let logWrites = await rig.restorer.logWrites
            XCTAssertEqual(logWrites, 1, "\(trigger) added=\(added)")
            let expected = RestoreResult.windows(restored: 1, total: 1, date: Date(timeIntervalSince1970: 50))
            XCTAssertEqual(rig.viewModel.lastResult, expected)
            XCTAssertEqual(rig.cycleFinishedOutcomes(), [.string("restored")])
        }
    }

    /// AC3: the held cycle records the session-not-ready note, changes nothing in the menu, never restores.
    @MainActor
    func testSessionNotReadyHoldIsNeverQuiet() async {
        let rig = makeQuietRig(readiness: FakeSessionReadiness(ready: false))
        await rig.fire()
        await rig.settle(from: 0)
        await rig.finish()
        let contexts = await rig.restorer.contexts
        XCTAssertTrue(contexts.isEmpty)
        XCTAssertEqual(rig.cycleFinishedOutcomes(), [.string("session-not-ready")])
        XCTAssertEqual(rig.viewModel.lastResult, QuietRig.previous)
        XCTAssertEqual(rig.viewModel.state, .idle)
        XCTAssertEqual(rig.center.posted, 0)
        await rig.controller.stop()
    }

    /// AC3: a resume only because the hold's bound expired restores as a normal wake.
    @MainActor
    func testHoldBoundExpiryResumeIsNeverQuiet() async {
        let rig = makeQuietRig(readiness: FakeSessionReadiness(ready: false),
                               schedule: SessionReadiness.Schedule(delays: [.seconds(1)], bound: .seconds(1)))
        await rig.fire()
        await rig.settle(from: 0)
        await rig.controller.waitUntilIdle()
        await rig.clock.waitForSleeper(deadline: .seconds(5))
        await rig.clock.advance(by: .seconds(1))
        await rig.settle(from: 5)
        await rig.finish()
        let contexts = await rig.restorer.contexts
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first?.trigger, .wake)
        XCTAssertEqual(contexts.first?.quietWake?.resumedByHoldBound, true)
        let logWrites = await rig.restorer.logWrites
        XCTAssertEqual(logWrites, 1)
        XCTAssertEqual(rig.cycleFinishedOutcomes(), [.string("session-not-ready"), .string("restored")])
        XCTAssertNotEqual(rig.viewModel.lastResult, QuietRig.previous)
    }

    /// AC3: a resume because readiness passed is classified normally, so it can be quiet.
    @MainActor
    func testReadinessResumeCanBeQuiet() async {
        let readiness = FakeSessionReadiness(ready: false)
        let rig = makeQuietRig(readiness: readiness)
        await rig.fire()
        await rig.settle(from: 0)
        await rig.controller.waitUntilIdle()
        readiness.set(true)
        await rig.controller.sessionMayBeReady()
        await rig.settle(from: 4)
        await rig.finish()
        let contexts = await rig.restorer.contexts
        XCTAssertEqual(contexts.first?.quietWake?.resumedByHoldBound, false)
        XCTAssertEqual(rig.cycleFinishedOutcomes(), [.string("session-not-ready"), .string("quiet")])
        XCTAssertEqual(rig.viewModel.lastResult, QuietRig.previous)
        XCTAssertEqual(rig.center.posted, 0)
        XCTAssertTrue(rig.gate.isOpen)
    }

    /// A1: a display added before a session-not-ready hold still counts after readiness resumes: the
    /// cycle is not quiet and writes its restore log.
    @MainActor
    func testAddedDisplaySurvivesSessionHoldAndIsNotQuiet() async {
        let readiness = FakeSessionReadiness(ready: false)
        let rig = makeQuietRig(readiness: readiness)
        await rig.fire(added: true)
        await rig.settle(from: 0)
        await rig.controller.waitUntilIdle()
        readiness.set(true)
        await rig.controller.sessionMayBeReady()
        await rig.settle(from: 4)
        await rig.finish()
        let contexts = await rig.restorer.contexts
        XCTAssertEqual(contexts.first?.quietWake,
                       QuietWakeEligibility(displaysAddedOrRemoved: true, resumedByHoldBound: false))
        let logWrites = await rig.restorer.logWrites
        XCTAssertEqual(logWrites, 1)
        XCTAssertEqual(rig.cycleFinishedOutcomes(), [.string("session-not-ready"), .string("restored")])
        XCTAssertNotEqual(rig.viewModel.lastResult, QuietRig.previous)
    }

    /// A1: a dropped-in-flight cycle retries with the added display still counted.
    @MainActor
    func testAddedDisplaySurvivesDroppedInFlightRetry() async {
        let rig = makeQuietRig(scripted: [.droppedInFlight])
        await rig.fire(added: true)
        await rig.finish()
        let contexts = await rig.restorer.contexts
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(contexts.last?.quietWake?.displaysAddedOrRemoved, true)
        let logWrites = await rig.restorer.logWrites
        XCTAssertEqual(logWrites, 1)
        XCTAssertNotEqual(rig.viewModel.lastResult, QuietRig.previous)
    }

    /// A1: an added display followed by a second, non-adding event still makes the restore non-quiet.
    @MainActor
    func testSecondFoldedEventKeepsAddedDisplayFlag() async {
        let rig = makeQuietRig()
        await rig.fire(added: true)
        await rig.fire(added: false)
        await rig.finish()
        let contexts = await rig.restorer.contexts
        XCTAssertTrue(contexts.contains { $0.quietWake?.displaysAddedOrRemoved == true })
        let logWrites = await rig.restorer.logWrites
        XCTAssertGreaterThanOrEqual(logWrites, 1)
        XCTAssertNotEqual(rig.viewModel.lastResult, QuietRig.previous)
    }

    /// A2: a failed cycle wrote no restore log, so the added display is re-armed for the next cycle.
    @MainActor
    func testFailedCycleReArmsAddedDisplayFlag() async {
        let rig = makeQuietRig(scripted: [.failed("boom")])
        await rig.fire(added: true)
        await rig.finish()
        await rig.fire(added: false)
        await rig.finish()
        let contexts = await rig.restorer.contexts
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(contexts.last?.quietWake?.displaysAddedOrRemoved, true)
        let logWrites = await rig.restorer.logWrites
        XCTAssertEqual(logWrites, 1)
    }
}
