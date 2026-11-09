import CoreGraphics
import XCTest
@testable import TotalRekall

private actor TrailPause: SnapshotPauseControlling {
    var learnedLayout: MonitorLayout { MonitorLayout(origins: [:]) }
    func runScheduledSnapshot() {}
}

private actor TrailRestorer: AutoRestoring {
    func restoreNow(context: CycleContext) async -> RestoreOutcome {
        .restored(RestoreSummary(results: [], date: Date(timeIntervalSince1970: 0)))
    }
    func fixMonitors(context: CycleContext) async -> RestoreOutcome {
        .monitorsFixed(.verified, date: Date(timeIntervalSince1970: 0))
    }
}

private actor QuietTrailRestorer: AutoRestoring {
    func restoreNow(context: CycleContext) async -> RestoreOutcome {
        let results = (1...3).map {
            RestoreWindowResult(snapshotID: UUID(), windowID: UInt32($0), bundleID: "com.example", appName: "App",
                                title: "t", status: .alreadyCorrect)
        }
        return .quietWake(RestoreSummary(results: results, date: Date(timeIntervalSince1970: 0),
                                         monitorFix: .alreadyInOrder))
    }
}

private struct TrailWake: WakeTracking {
    func triggerForDisplayChange() -> CycleTrigger { .wake }
}

private final class TrailTrust: AccessibilityTrustChecking, Sendable {
    func isProcessTrusted() -> Bool { true }
}

private actor TrailStatus: AutomationStatusReporting {
    func automationDidBegin() {}
    func automationDidFinish(outcome: RestoreOutcome?) {}
}

private actor TrailCapturer: SnapshotCapturing {
    var outcome: SnapshotSaveOutcome
    init(outcome: SnapshotSaveOutcome) { self.outcome = outcome }
    func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult {
        SnapshotCaptureResult(reason: reason, outcome: outcome,
                              layout: MonitorLayout(origins: ["a": .init(x: 0, y: 0)]),
                              configKey: "k", windowCount: 0)
    }
}

private actor ResultBox<T: Sendable> {
    private(set) var value: T?
    func set(_ newValue: T) { value = newValue }
}

final class DiagnosticsAutomationTrailTests: XCTestCase {
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }

    /// Bounded replacement for `controller.waitUntilIdle()`. The wait runs in an unstructured Task that is
    /// abandoned at the deadline: a task group would await a non-cancellable child on exit and still hang.
    private func waitIdle(_ controller: AutomationController, timeout: TimeInterval = 5) async {
        let box = ResultBox<Bool>()
        let waiter = Task { await controller.waitUntilIdle(); await box.set(true) }
        let finished = await waitUntil(timeout: timeout) { await box.value != nil }
        waiter.cancel()
        XCTAssertTrue(finished, "controller did not become idle within \(timeout)s")
    }

    func testAutomaticCycleTrailOrder() async throws {
        let diag = RecordingDiagnostics()
        let gate = SnapshotGate()
        let monitorClock = TestClock()
        let window = Duration.milliseconds(1500)
        let monitor = DisplayMonitor(debounce: window, clock: monitorClock, snapshotGate: gate, diagnostics: diag)
        await monitor.startProcessing()
        // Cancel the monitor's processing/settle tasks when the test ends so nothing leaks into later tests.
        addTeardownBlock { await monitor.stop() }

        let (stream, _) = AsyncStream.makeStream(of: DisplayChangeEvent.self)
        let controller = AutomationController(
            events: stream, gate: gate, pause: TrailPause(), restorer: TrailRestorer(), trust: TrailTrust(),
            status: TrailStatus(), liveLayout: { MonitorLayout(origins: [:]) },
            clock: TestClock(immediate: true), diagnostics: diag
        )
        addTeardownBlock { await controller.stop() }

        // A replug: several raw callbacks, only the first closes the gate (one gate-closed record).
        for flags: CGDisplayChangeSummaryFlags in [.beginConfigurationFlag, .addFlag, .movedFlag] {
            monitor.receive(RawDisplayEvent(displayID: 7, flags: flags.rawValue, vendorID: 0x10AC,
                                            source: .reconfigurationCallback))
        }
        // The raw stream is drained asynchronously. Advancing the clock before all three events are ingested
        // fires a window that a later ingest then supersedes (new sleeper at 2x the deadline, never advanced),
        // so no settled event would ever arrive. Wait for every ingest first.
        let ingested = await waitUntil { await monitor.ingestedCount == 3 }
        XCTAssertTrue(ingested, "monitor did not ingest all raw events")

        // Each ingest cancels the previous sleeper asynchronously and the newest sleeper registers on its own
        // task, so a sleeper at the deadline may be a stale one. Advancing is idempotent for stale sleepers
        // (their settle token no longer matches), so advance until the real settle lands.
        let box = ResultBox<DisplayChangeEvent>()
        let reader = Task {
            var iterator = monitor.events.makeAsyncIterator()
            if let event = await iterator.next() { await box.set(event) }
        }
        defer { reader.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while await box.value == nil, Date() < deadline {
            await monitorClock.advance(by: window)
            try? await Task.sleep(for: .milliseconds(5))
        }
        let settled = await box.value
        let event = try XCTUnwrap(settled, "no settled event within 5s")
        await controller.receive(event)
        await waitIdle(controller)

        let names = diag.events.map(\.name)
        XCTAssertEqual(names, ["gate-closed", "display-settled", "cycle-started", "docked-set-wait",
                               "cycle-finished", "gate-reopened"])

        let byName = Dictionary(uniqueKeysWithValues: diag.events.map { ($0.name, $0) })
        XCTAssertEqual(byName["gate-closed"]?.fields["epoch"], .int(1))
        XCTAssertEqual(byName["display-settled"]?.fields["rawEventCount"], .int(3))
        XCTAssertEqual(byName["cycle-started"]?.fields["trigger"], .string("display-change"))
        XCTAssertEqual(byName["gate-reopened"]?.fields["epoch"], .int(1))
        XCTAssertEqual(byName["cycle-finished"]?.fields["outcome"], .string("restored"))

        let cycleEvents = ["cycle-started", "docked-set-wait", "cycle-finished", "gate-reopened"].compactMap { byName[$0]?.cycleID }
        XCTAssertEqual(cycleEvents.count, 4)
        XCTAssertEqual(Set(cycleEvents).count, 1)
    }

    /// AC1: a quiet wake's cycle-finished reads outcome=quiet with restored/total and needsAttention=false,
    /// for the same cycleID the cycle started with, and the gate still reopens.
    func testQuietWakeCycleFinishedOutcomeQuiet() async {
        let diag = RecordingDiagnostics()
        let gate = SnapshotGate()
        let (stream, _) = AsyncStream.makeStream(of: DisplayChangeEvent.self)
        let controller = AutomationController(
            events: stream, gate: gate, pause: TrailPause(), restorer: QuietTrailRestorer(), trust: TrailTrust(),
            status: TrailStatus(), liveLayout: { MonitorLayout(origins: [:]) },
            clock: TestClock(immediate: true), wake: TrailWake(), diagnostics: diag
        )
        addTeardownBlock { await controller.stop() }
        let epoch = gate.closeForDisplayChange()
        await controller.receive(DisplayChangeEvent(moved: [1], rawEventCount: 1, throughEpoch: epoch))
        await waitIdle(controller)

        let started = diag.events.first { $0.name == "cycle-started" }
        let finished = diag.events.first { $0.name == "cycle-finished" }
        XCTAssertEqual(started?.fields["trigger"], .string("wake"))
        XCTAssertEqual(finished?.cycleID, started?.cycleID)
        XCTAssertEqual(finished?.fields["outcome"], .string("quiet"))
        XCTAssertEqual(finished?.fields["restored"], .int(3))
        XCTAssertEqual(finished?.fields["total"], .int(3))
        XCTAssertEqual(finished?.fields["needsAttention"], .bool(false))
        XCTAssertTrue(diag.events.contains { $0.name == "gate-reopened" })
    }

    func testSuppressedSelfChangesAreCountedNotRecordedEach() {
        let diag = RecordingDiagnostics()
        let monitor = DisplayMonitor(diagnostics: diag)
        monitor.beginSelfChange()
        for _ in 0..<3 {
            monitor.receive(RawDisplayEvent(displayID: 1, flags: CGDisplayChangeSummaryFlags.movedFlag.rawValue,
                                            vendorID: 0x10AC, source: .reconfigurationCallback))
        }
        XCTAssertTrue(diag.events.isEmpty)
        monitor.endSelfChange()
        XCTAssertEqual(diag.events.map(\.name), ["display-suppressed"])
        XCTAssertEqual(diag.events.first?.fields["count"], .int(3))
    }

    func testZeroWindowCaptureRecordsSkipReason() async {
        let diag = RecordingDiagnostics()
        let coord = SnapshotCoordinator(capturer: TrailCapturer(outcome: .skippedZeroWindows(priorCount: 4)),
                                        gate: SnapshotGate(), liveLayout: { MonitorLayout(origins: [:]) },
                                        diagnostics: diag)
        await coord.runScheduledSnapshot()
        XCTAssertEqual(diag.events.map(\.name), ["snapshot-skipped"])
        XCTAssertEqual(diag.events.first?.fields["reason"], .string("zero-window-guard"))
    }

    func testGateDiscardedCaptureRecordsSkipReason() async {
        let diag = RecordingDiagnostics()
        let coord = SnapshotCoordinator(capturer: TrailCapturer(outcome: .discardedGateClosed),
                                        gate: SnapshotGate(), liveLayout: { MonitorLayout(origins: [:]) },
                                        diagnostics: diag)
        await coord.runScheduledSnapshot()
        XCTAssertEqual(diag.events.map(\.name), ["snapshot-skipped"])
        XCTAssertEqual(diag.events.first?.fields["reason"], .string("gate-discarded-at-commit"))
    }

    func testClosedGateSkipsTickAndRefusesManualSave() async {
        let diag = RecordingDiagnostics()
        let gate = SnapshotGate()
        let coord = SnapshotCoordinator(capturer: TrailCapturer(outcome: .written), gate: gate,
                                        liveLayout: { MonitorLayout(origins: [:]) }, diagnostics: diag)
        _ = gate.closeForDisplayChange()
        await coord.runScheduledSnapshot()
        _ = await coord.saveManually()
        XCTAssertEqual(diag.events.map(\.name), ["snapshot-skipped", "snapshot-refused"])
        XCTAssertEqual(diag.events.last?.fields["refusal"], .string("display-change-in-progress"))
        XCTAssertEqual(diag.events.last?.fields["epoch"], .int(1))
    }

    func testWrittenSnapshotRecordsCounts() async {
        let diag = RecordingDiagnostics()
        let coord = SnapshotCoordinator(capturer: TrailCapturer(outcome: .written), gate: SnapshotGate(),
                                        liveLayout: { MonitorLayout(origins: [:]) }, diagnostics: diag)
        _ = await coord.saveManually()
        XCTAssertEqual(diag.events.map(\.name), ["snapshot-written"])
        XCTAssertEqual(diag.events.first?.fields["panelSerials"], .int(1))
        XCTAssertEqual(diag.events.first?.fields["windows"], .int(0))
    }
}
