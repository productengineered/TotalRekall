import XCTest
@testable import TotalRekall

private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}

/// Records the context of every restore/fix; can block inside a restore.
private actor ContextRestorer: AutoRestoring {
    private(set) var restoreContexts: [CycleContext] = []
    private(set) var fixContexts: [CycleContext] = []
    private var release: CheckedContinuation<Void, Never>?
    private var blockFirst: Bool
    init(blockFirst: Bool = false) { self.blockFirst = blockFirst }

    func unblock() { release?.resume(); release = nil }

    func restoreNow(context: CycleContext) async -> RestoreOutcome {
        restoreContexts.append(context)
        if blockFirst {
            blockFirst = false
            await withCheckedContinuation { release = $0 }
        }
        return .restored(RestoreSummary(results: [], date: Date(timeIntervalSince1970: 0)))
    }

    func fixMonitors(context: CycleContext) async -> RestoreOutcome {
        fixContexts.append(context)
        return .monitorsFixed(.verified, date: Date())
    }
}

private actor QuietPause: SnapshotPauseControlling {
    var learnedLayout: MonitorLayout { MonitorLayout(origins: [:]) }
    func runScheduledSnapshot() {}
}

private actor QuietStatus: AutomationStatusReporting {
    private(set) var finishContexts: [CycleContext] = []
    func automationDidBegin() {}
    func automationDidFinish(outcome: RestoreOutcome?) {}
    func automationDidFinish(outcome: RestoreOutcome?, context: CycleContext) { finishContexts.append(context) }
}

private final class Trust: AccessibilityTrustChecking, @unchecked Sendable {
    private let box: Box<Bool>
    init(_ trusted: Bool) { box = Box(trusted) }
    func set(_ v: Bool) { box.set(v) }
    func isProcessTrusted() -> Bool { box.get() }
}

final class AutomationTriggerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private struct Rig {
        let controller: AutomationController
        let gate: SnapshotGate
        let restorer: ContextRestorer
        let status: QuietStatus
        let trust: Trust
        let wake: SystemWakeObserver
        let time: Box<Date>

        func fire() async {
            let epoch = gate.closeForDisplayChange()
            await controller.receive(DisplayChangeEvent(added: [1], rawEventCount: 1, throughEpoch: epoch))
        }
    }

    private func makeRig(trusted: Bool = true, blockFirst: Bool = false, immediate: Bool = true) -> Rig {
        let gate = SnapshotGate()
        let restorer = ContextRestorer(blockFirst: blockFirst)
        let status = QuietStatus()
        let trust = Trust(trusted)
        let time = Box(t0)
        let wake = SystemWakeObserver(now: { time.get() }, diagnostics: RecordingDiagnostics())
        let (stream, _) = AsyncStream.makeStream(of: DisplayChangeEvent.self)
        let controller = AutomationController(
            events: stream, gate: gate, pause: QuietPause(), restorer: restorer, trust: trust, status: status,
            liveLayout: { MonitorLayout(origins: [:]) }, clock: TestClock(immediate: immediate),
            wake: wake, now: { time.get() }
        )
        return Rig(controller: controller, gate: gate, restorer: restorer, status: status, trust: trust,
                   wake: wake, time: time)
    }

    func testDisplayChangeThreeSecondsAfterWakeIsLabeledWake() async {
        let rig = makeRig()
        rig.wake.note(.systemWake)
        rig.time.set(t0.addingTimeInterval(3))
        await rig.fire()
        await rig.controller.waitUntilIdle()
        let contexts = await rig.restorer.restoreContexts
        XCTAssertEqual(contexts.map(\.trigger), [.wake])
    }

    func testDisplayChangeThirtySecondsAfterWakeIsDisplayChange() async {
        let rig = makeRig()
        rig.wake.note(.systemWake)
        rig.time.set(t0.addingTimeInterval(30))
        await rig.fire()
        await rig.controller.waitUntilIdle()
        let contexts = await rig.restorer.restoreContexts
        XCTAssertEqual(contexts.map(\.trigger), [.displayChange])
    }

    func testDisplayChangeWithoutAnyWakeIsDisplayChange() async {
        let rig = makeRig()
        await rig.fire()
        await rig.controller.waitUntilIdle()
        let contexts = await rig.restorer.restoreContexts
        XCTAssertEqual(contexts.map(\.trigger), [.displayChange])
    }

    func testScreensWakeAlsoCountsAsWake() {
        let wake = SystemWakeObserver(now: { Date(timeIntervalSince1970: 1_000_000) }, diagnostics: RecordingDiagnostics())
        wake.note(.screensWake)
        XCTAssertEqual(wake.triggerForDisplayChange(), .wake)
    }

    func testSleepAloneDoesNotCountAsWake() {
        let wake = SystemWakeObserver(now: { Date(timeIntervalSince1970: 1_000_000) }, diagnostics: RecordingDiagnostics())
        wake.note(.systemSleep)
        wake.note(.screensSleep)
        XCTAssertEqual(wake.triggerForDisplayChange(), .displayChange)
    }

    func testSleepAndWakeAreRecordedInDiagnostics() {
        let diagnostics = RecordingDiagnostics()
        let wake = SystemWakeObserver(now: { Date(timeIntervalSince1970: 1_000_000) }, diagnostics: diagnostics)
        wake.note(.systemSleep)
        wake.note(.systemWake)
        XCTAssertEqual(diagnostics.events.map(\.name), ["system-sleep", "system-wake"])
    }

    func testLaunchCheckUsesLaunchTrigger() async {
        let rig = makeRig(immediate: false)
        await rig.controller.start()
        var contexts: [CycleContext] = []
        for _ in 0..<10_000 where contexts.isEmpty {
            await Task.yield()
            contexts = await rig.restorer.fixContexts
        }
        await rig.controller.stop()
        XCTAssertEqual(contexts.map(\.trigger), [.launch])
    }

    func testManualRunsUseManualTrigger() async {
        XCTAssertEqual(CycleContext.manual().trigger, .manual)
        let restorer = ContextRestorer()
        _ = await restorer.restoreNow()   // default no-context form forwards with a manual context
        _ = await restorer.fixMonitors()
        let restoreContexts = await restorer.restoreContexts
        let fixContexts = await restorer.fixContexts
        XCTAssertEqual(restoreContexts.map(\.trigger), [.manual])
        XCTAssertEqual(fixContexts.map(\.trigger), [.manual])
    }

    func testQueuedFollowUpGetsANewCycleID() async {
        let rig = makeRig(blockFirst: true)
        await rig.fire()
        for _ in 0..<10_000 {
            if await rig.restorer.restoreContexts.count >= 1 { break }
            await Task.yield()
        }
        await rig.fire()                       // arrives during the restore: queues a follow-up
        await rig.restorer.unblock()
        await rig.controller.waitUntilIdle()
        let contexts = await rig.restorer.restoreContexts
        XCTAssertEqual(contexts.count, 2)
        XCTAssertNotEqual(contexts.first?.cycleID, contexts.last?.cycleID)
    }

    func testCycleResumedAfterAccessibilityReturnsKeepsItsTrigger() async {
        let rig = makeRig(trusted: false)
        rig.wake.note(.systemWake)
        rig.time.set(t0.addingTimeInterval(2))
        await rig.fire()
        await rig.controller.waitUntilIdle()
        let before = await rig.restorer.restoreContexts
        XCTAssertTrue(before.isEmpty)

        rig.time.set(t0.addingTimeInterval(120))   // well outside the wake window now
        rig.trust.set(true)
        await rig.controller.accessibilityChanged(trusted: true)
        await rig.controller.waitUntilIdle()
        let contexts = await rig.restorer.restoreContexts
        XCTAssertEqual(contexts.map(\.trigger), [.wake])
    }

    func testStatusReceivesTheCycleContext() async {
        let rig = makeRig()
        await rig.fire()
        await rig.controller.waitUntilIdle()
        let restoreContexts = await rig.restorer.restoreContexts
        let finishContexts = await rig.status.finishContexts
        XCTAssertEqual(finishContexts, restoreContexts)
    }
}
