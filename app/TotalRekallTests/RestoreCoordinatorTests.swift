import XCTest
@testable import TotalRekall

// MARK: - Fakes

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private struct FakeTrust: AccessibilityTrustChecking {
    let trusted: Bool
    func isProcessTrusted() -> Bool { trusted }
}

private struct FakeDisplays: DisplayProviding {
    let serials: [String]
    func currentDisplays() -> [LiveDisplay] {
        serials.enumerated().map { index, s in
            LiveDisplay(displayID: UInt32(index + 1), serial: s == "builtin" ? .builtin : .panel(s),
                        frame: SnapshotFrame(x: 0, y: 0, width: 100, height: 100),
                        pixelSize: SnapshotSize(width: 100, height: 100), scaleFactor: 1, name: s,
                        vendorID: 1, productID: 1, serialNumber: s, unitNumber: 0, isMain: index == 0)
        }
    }
}

private struct FakeSnapshots: SnapshotLoading {
    let file: SnapshotFile
    func load() async throws -> SnapshotFile { file }
}

private struct FakeFixer: MonitorFixing {
    let log: CallLog
    let outcome: FixOutcome
    var learnedLog: CallLog?
    func fix(learned: MonitorLayout) -> FixOutcome {
        log.add("fix")
        let serials = learned.origins.sorted { $0.key < $1.key }.map { "\($0.key)@\($0.value.x)" }
        learnedLog?.add(serials.joined(separator: ","))
        return outcome
    }
}

private struct FakeTopology: SpaceTopologyProviding {
    let log: CallLog
    func topology() async throws -> [DisplaySpaces] { log.add("topology"); return [] }
}

private struct FakeLive: LiveWindowProviding {
    let log: CallLog
    func liveWindows(ids: Set<UInt32>) async -> [LiveWindowState] { log.add("live"); return [] }
}

private struct FakeLogWriter: RestoreLogWriting {
    let log: CallLog
    func write(_ log: RestoreLog) throws { self.log.add("log") }
}

/// Reports every planned window with `status`. With `blocks`, only the FIRST execute suspends until
/// `release()`; later runs return immediately (a blocking re-run would hang the test forever).
private final class FakeRestorer: WindowRestoring, @unchecked Sendable {
    let log: CallLog
    let statuses: [RestoreStatus]
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    let blocks: Bool

    init(log: CallLog, statuses: [RestoreStatus], blocks: Bool = false) {
        self.log = log
        self.statuses = statuses
        self.blocks = blocks
    }

    /// Marks entry; returns true only for the first call when blocking.
    private func enter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let first = !entered
        entered = true
        return blocks && first
    }

    /// Stores the continuation, or resumes it at once if `release()` already ran (no lost wakeup).
    private func park(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if released { lock.unlock(); c.resume(); return }
        continuation = c
        lock.unlock()
    }

    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }

    func release() {
        lock.lock(); released = true; let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }

    func execute(_ plan: RestorePlan) async -> [RestoreWindowResult] {
        log.add("restore")
        if enter() {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in park(c) }
        }
        return zip(plan.windows, statuses).map { RestoreWindowResult(planned: $0.0, status: $0.1) }
    }
}

// MARK: - Tests

final class RestoreCoordinatorTests: XCTestCase {
    private let serials = ["builtin", "PANEL1"]

    private func window(_ id: UInt32) -> WindowSnapshot {
        WindowSnapshot(
            id: UUID(), bundleID: "com.example", appName: "App", windowID: id, windowTitle: "W\(id)",
            windowIndex: 0, displayFingerprint: nil, displayIndex: 0, panelSerial: "builtin", spaceOrdinal: 1,
            spaceUUID: nil, spaceIndex: 0, frame: SnapshotFrame(x: 0, y: 0, width: 10, height: 10),
            isFullscreen: false, isMinimized: false, zOrder: 0
        )
    }

    private func snapshotFile(windowCount: Int = 2) -> SnapshotFile {
        let key = SnapshotKey.make(panelSerials: serials)
        let displays = serials.enumerated().map { index, s in
            DisplaySnapshot(vendorID: 1, productID: 1, serialNumber: s, panelSerial: s, unitNumber: 0,
                            iokitLocationPath: nil, resolution: SnapshotSize(width: 100, height: 100),
                            scaleFactor: 1, displayName: s, originX: index * 100, originY: 0,
                            isMain: index == 0, cgDisplayID: nil)
        }
        let config = DisplayConfigSnapshot(
            fingerprint: key, displayConfigName: "test", displays: displays, lastSnapshotDate: Date(),
            windows: (0..<windowCount).map { window(UInt32($0 + 1)) }
        )
        return SnapshotFile(configurations: [key: config])
    }

    private func makeSUT(
        log: CallLog, trusted: Bool = true, file: SnapshotFile? = nil,
        restorer: WindowRestoring? = nil, fix: FixOutcome = .verified,
        learned: MonitorLayout = MonitorLayout(origins: [:]), learnedLog: CallLog? = nil
    ) -> RestoreCoordinator {
        RestoreCoordinator(
            trust: FakeTrust(trusted: trusted), displays: FakeDisplays(serials: serials),
            snapshots: FakeSnapshots(file: file ?? snapshotFile()), learnedLayout: { learned },
            fixer: FakeFixer(log: log, outcome: fix, learnedLog: learnedLog), topology: FakeTopology(log: log),
            liveWindows: FakeLive(log: log),
            restorer: restorer ?? FakeRestorer(log: log, statuses: [.moved, .moved]),
            logWriter: FakeLogWriter(log: log),
            capability: .full, now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    func testRestoreNowRunsPipelineInSpecOrder() async {
        let log = CallLog()
        let outcome = await makeSUT(log: log).restoreNow()
        XCTAssertEqual(log.entries, ["fix", "topology", "live", "restore", "log"])
        guard case .restored(let summary) = outcome else { return XCTFail("expected restored, got \(outcome)") }
        XCTAssertEqual(summary.restored, 2)
        XCTAssertFalse(summary.needsAttention)
    }

    func testMissingAccessibilityRefusesWithoutTouchingAnything() async {
        let log = CallLog()
        let sut = makeSUT(log: log, trusted: false)
        let restore = await sut.restoreNow()
        let fix = await sut.fixMonitors()
        XCTAssertEqual(restore, .refusedNoAccessibility)
        XCTAssertEqual(fix, .refusedNoAccessibility)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testSecondConcurrentRestoreIsDropped() async {
        let log = CallLog()
        let restorer = FakeRestorer(log: log, statuses: [.moved, .moved], blocks: true)
        let sut = makeSUT(log: log, restorer: restorer)

        let first = Task { await sut.restoreNow() }
        for _ in 0..<10_000 where !restorer.hasEntered { await Task.yield() }
        XCTAssertTrue(restorer.hasEntered)

        let second = await sut.restoreNow()
        let fixWhileRunning = await sut.fixMonitors()
        XCTAssertEqual(second, .droppedInFlight)
        XCTAssertEqual(fixWhileRunning, .droppedInFlight)

        restorer.release()
        let firstOutcome = await first.value
        guard case .restored = firstOutcome else { return XCTFail("first run should complete") }
        XCTAssertEqual(log.entries.filter { $0 == "restore" }.count, 1)
        let again = await sut.restoreNow()
        XCTAssertNotEqual(again, .droppedInFlight)
    }

    func testFixMonitorsRunsOnlyTheMonitorStep() async {
        let log = CallLog()
        let outcome = await makeSUT(log: log).fixMonitors()
        XCTAssertEqual(log.entries, ["fix"])
        XCTAssertEqual(outcome, .monitorsFixed(.verified, date: Date(timeIntervalSince1970: 1_000)))
    }

    func testNoSnapshotForConnectedDisplays() async {
        let log = CallLog()
        let outcome = await makeSUT(log: log, file: SnapshotFile()).restoreNow()
        XCTAssertEqual(outcome, .noSnapshot)
        XCTAssertTrue(log.entries.isEmpty)
    }

    /// The swap check uses LearnedLayoutStore's layout (learned before the pause) and falls back to
    /// the latest snapshot's origins only when nothing is learned yet.
    func testSwapCheckUsesLearnedLayoutWithSnapshotFallback() async {
        let learned = MonitorLayout(origins: ["builtin": .init(x: 0, y: 0), "PANEL1": .init(x: -500, y: 0)])
        let cases: [(MonitorLayout, String)] = [
            (learned, "PANEL1@-500,builtin@0"),
            (MonitorLayout(origins: [:]), "PANEL1@100,builtin@0")  // snapshot file origins
        ]
        for (input, expected) in cases {
            let learnedLog = CallLog()
            _ = await makeSUT(log: CallLog(), learned: input, learnedLog: learnedLog).fixMonitors()
            XCTAssertEqual(learnedLog.entries, [expected])
        }
    }

    @MainActor
    func testPartialRestorePublishesLastResultAndAttention() async {
        let log = CallLog()
        let restorer = FakeRestorer(log: log, statuses: [.moved, .failed])
        let outcome = await makeSUT(log: log, restorer: restorer).restoreNow()
        let viewModel = MenuBarViewModel()
        viewModel.apply(outcome)
        XCTAssertEqual(viewModel.state, .attention)
        guard case .windows(let restored, let total, _) = viewModel.lastResult else {
            return XCTFail("expected a windows result")
        }
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(total, 2)
    }

    @MainActor
    func testApplyOutcomeStates() {
        let date = Date(timeIntervalSince1970: 5)
        let cases: [(RestoreOutcome, AppState)] = [
            (.noSnapshot, .idle),
            (.failed("x"), .attention),
            (.monitorsFixed(.verified, date: date), .idle),
            (.monitorsFixed(.failed(reason: "x"), date: date), .attention)
        ]
        for (outcome, expected) in cases {
            let viewModel = MenuBarViewModel()
            viewModel.state = .working
            viewModel.apply(outcome)
            XCTAssertEqual(viewModel.state, expected, "\(outcome)")
        }
        let denied = MenuBarViewModel()
        denied.apply(.refusedNoAccessibility)
        XCTAssertFalse(denied.accessibilityGranted)
        XCTAssertEqual(denied.statusLine, "Accessibility access needed")

        let dropped = MenuBarViewModel()
        dropped.state = .working
        dropped.apply(.droppedInFlight, previousState: .working)
        XCTAssertEqual(dropped.state, .working)
    }
}

// MARK: - Own window (Bug 65)

extension RestoreCoordinatorTests {
    /// Snapshots written before own windows were excluded still hold Total Rekall's window; the restore
    /// never plans it, so "N of M" counts only the user's windows.
    func testOwnBundleWindowInExistingSnapshotIsNotPlanned() async {
        let log = CallLog()
        var file = snapshotFile(windowCount: 2)
        let key = SnapshotKey.make(panelSerials: serials)
        let own = WindowSnapshot(
            id: UUID(), bundleID: "com.productengineered.TotalRekall", appName: "Total Rekall", windowID: 158_216,
            windowTitle: "Total Rekall", windowIndex: 0, displayFingerprint: nil, displayIndex: 0,
            panelSerial: "builtin", spaceOrdinal: 1, spaceUUID: nil, spaceIndex: 0,
            frame: SnapshotFrame(x: 0, y: 0, width: 10, height: 10), isFullscreen: false, isMinimized: false, zOrder: 2)
        file.configurations[key]?.windows.append(own)
        let sut = RestoreCoordinator(
            trust: FakeTrust(trusted: true), displays: FakeDisplays(serials: serials),
            snapshots: FakeSnapshots(file: file), fixer: FakeFixer(log: log, outcome: .verified),
            topology: FakeTopology(log: log), liveWindows: FakeLive(log: log),
            restorer: FakeRestorer(log: log, statuses: [.moved, .moved, .moved]), logWriter: FakeLogWriter(log: log),
            capability: .full, now: { Date(timeIntervalSince1970: 1_000) },
            ownBundleID: "com.productengineered.TotalRekall")
        guard case .restored(let summary) = await sut.restoreNow() else { return XCTFail("expected restored") }
        XCTAssertEqual(summary.total, 2)
    }
}

// MARK: - Quiet wake

extension RestoreCoordinatorTests {
    private func quietSUT(log: CallLog, diagnostics: RecordingDiagnostics) -> RestoreCoordinator {
        RestoreCoordinator(
            trust: FakeTrust(trusted: true), displays: FakeDisplays(serials: serials),
            snapshots: FakeSnapshots(file: snapshotFile()), fixer: FakeFixer(log: log, outcome: .alreadyInOrder),
            topology: FakeTopology(log: log), liveWindows: FakeLive(log: log),
            restorer: FakeRestorer(log: log, statuses: [.alreadyCorrect, .alreadyCorrect]),
            logWriter: FakeLogWriter(log: log), capability: .full, now: { Date(timeIntervalSince1970: 1_000) },
            diagnostics: diagnostics, ownBundleID: "com.productengineered.TotalRekall")
    }

    private static let eligible = QuietWakeEligibility(displaysAddedOrRemoved: false, resumedByHoldBound: false)

    /// AC1: the plan and every window result are recorded, restore-finished carries quiet=true, and
    /// restore-log.json is never written.
    func testQuietWakeSkipsRestoreLogWrite() async {
        let log = CallLog()
        let diagnostics = RecordingDiagnostics()
        let context = CycleContext(trigger: .wake, quietWake: Self.eligible)
        let outcome = await quietSUT(log: log, diagnostics: diagnostics).restoreNow(context: context)

        guard case .quietWake(let summary) = outcome else { return XCTFail("expected quietWake, got \(outcome)") }
        XCTAssertEqual(summary.restored, 2)
        XCTAssertEqual(summary.total, 2)
        XCTAssertFalse(log.entries.contains("log"), "a quiet wake never rewrites restore-log.json")
        let events = diagnostics.events.filter { $0.cycleID == context.cycleID }
        XCTAssertEqual(events.filter { $0.name == "restore-plan" }.count, 1)
        XCTAssertEqual(events.filter { $0.name == "window-result" }.count, 2)
        let finished = events.first { $0.name == "restore-finished" }
        XCTAssertEqual(finished?.fields["quiet"], .bool(true))
        XCTAssertEqual(finished?.fields["restored"], .int(2))
    }

    /// AC8: the same all-already-correct run is a normal restore for every other trigger (and for a
    /// wake without eligibility): the log is written and restore-finished has no quiet field.
    func testNonWakeAllAlreadyCorrectStillWritesRestoreLog() async {
        let contexts = [CycleContext(trigger: .displayChange, quietWake: Self.eligible), .manual(),
                        CycleContext(trigger: .wake)]
        for context in contexts {
            let log = CallLog()
            let diagnostics = RecordingDiagnostics()
            let outcome = await quietSUT(log: log, diagnostics: diagnostics).restoreNow(context: context)
            guard case .restored = outcome else { return XCTFail("\(context.trigger): expected restored") }
            XCTAssertTrue(log.entries.contains("log"), "\(context.trigger)")
            let finished = diagnostics.events.first { $0.name == "restore-finished" }
            XCTAssertNil(finished?.fields["quiet"], "\(context.trigger)")
        }
    }

    @MainActor
    func testQuietWakeApplyLeavesMenuStateUntouched() {
        let viewModel = MenuBarViewModel()
        let previous = RestoreResult.windows(restored: 3, total: 4, date: Date(timeIntervalSince1970: 1))
        viewModel.lastResult = previous
        viewModel.state = .working
        let quiet = RestoreOutcome.quietWake(RestoreSummary(results: [], date: Date(timeIntervalSince1970: 2)))
        viewModel.apply(quiet, previousState: .attention)
        XCTAssertEqual(viewModel.state, .attention, "the icon goes back to what it was")
        XCTAssertEqual(viewModel.lastResult, previous)
        XCTAssertNil(viewModel.lastRestoreDetail)
        XCTAssertFalse(quiet.setsAttention)
    }
}
