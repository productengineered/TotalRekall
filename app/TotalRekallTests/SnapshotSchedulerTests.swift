import XCTest
@testable import TotalRekall

/// Returns a canned result. `duringCapture` runs mid-capture (e.g. to simulate a display callback).
private actor FakeCapturer: SnapshotCapturing {
    private(set) var reasons: [SnapshotReason] = []
    var layoutToReturn = MonitorLayout(origins: [:])
    var outcome: SnapshotSaveOutcome = .written
    var duringCapture: (@Sendable () -> Void)?

    func setLayout(_ l: MonitorLayout) { layoutToReturn = l }
    func setDuringCapture(_ hook: @escaping @Sendable () -> Void) { duringCapture = hook }

    func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult {
        reasons.append(reason)
        duringCapture?()
        return SnapshotCaptureResult(reason: reason, outcome: outcome, layout: layoutToReturn,
                                     configKey: "k", windowCount: 3)
    }
}

/// Mirrors SnapshotService's write: a real SnapshotStore save through the token, after a hook that
/// stands in for the awaits (Spaces, per-window lookups) between token and commit.
private struct StoreBackedCapturer: SnapshotCapturing {
    let store: SnapshotStore
    let layout: MonitorLayout
    let beforeSave: @Sendable () -> Void

    func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult {
        beforeSave()
        let window = WindowSnapshot(
            id: UUID(), bundleID: "com.example", appName: "App", windowID: 1, windowTitle: "W",
            windowIndex: 0, displayFingerprint: nil, displayIndex: 0, panelSerial: "a", spaceOrdinal: 1,
            spaceUUID: nil, spaceIndex: 0, frame: SnapshotFrame(x: 0, y: 0, width: 10, height: 10),
            isFullscreen: false, isMinimized: false, zOrder: 0)
        let config = DisplayConfigSnapshot(fingerprint: "k", displayConfigName: "t", displays: [],
                                           lastSnapshotDate: Date(), windows: [window])
        let outcome = try await store.save(config, key: "k", ifGate: token)
        return SnapshotCaptureResult(reason: reason, outcome: outcome, layout: layout, configKey: "k", windowCount: 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

private final class LiveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var l: MonitorLayout
    init(_ l: MonitorLayout) { self.l = l }
    var value: MonitorLayout { get { lock.lock(); defer { lock.unlock() }; return l }
                               set { lock.lock(); l = newValue; lock.unlock() } }
}

final class SnapshotSchedulerTests: XCTestCase {
    private func layout(_ serials: [String]) -> MonitorLayout {
        var map: [String: MonitorLayout.Origin] = [:]
        for (i, s) in serials.enumerated() { map[s] = .init(x: i * 1000, y: 0) }
        return MonitorLayout(origins: map)
    }

    func testSchedulerFiresAtLaunchThenEvery600Seconds() async {
        let clock = TestClock()
        let counter = Counter()
        let scheduler = SnapshotScheduler(clock: clock) { counter.bump() }
        await scheduler.start()
        // The loop ticks, then sleeps: a sleeper at 600 s proves exactly one tick ran.
        await clock.waitForSleeper(deadline: .seconds(600))
        XCTAssertEqual(counter.value, 1)
        await clock.advance(by: .seconds(599))
        XCTAssertEqual(counter.value, 1, "the 600 s sleeper is not due yet")
        await clock.advance(by: .seconds(1))
        await clock.waitForSleeper(deadline: .seconds(1200))
        XCTAssertEqual(counter.value, 2)
        await clock.advance(by: .seconds(600))
        await clock.waitForSleeper(deadline: .seconds(1800))
        XCTAssertEqual(counter.value, 3)
        await scheduler.stop()
    }

    func testPausedScheduledTickWritesNothing() async {
        let cap = FakeCapturer()
        let gate = SnapshotGate()
        let l = layout(["a", "b"])
        let coord = SnapshotCoordinator(capturer: cap, gate: gate, liveLayout: { l })
        let epoch = gate.closeForDisplayChange()
        await coord.runScheduledSnapshot()
        let n1 = await cap.reasons.count
        XCTAssertEqual(n1, 0)
        gate.reopen(ifEpoch: epoch)
        await coord.runScheduledSnapshot()
        let reasons = await cap.reasons
        XCTAssertEqual(reasons, [.periodic])
    }

    func testManualSaveRefusedDuringPauseWithMessage() async {
        let cap = FakeCapturer()
        let gate = SnapshotGate()
        let l = layout(["a"])
        let coord = SnapshotCoordinator(capturer: cap, gate: gate, liveLayout: { l })
        let epoch = gate.closeForDisplayChange()
        let r = await coord.saveManually()
        XCTAssertEqual(r, .refused(message: SnapshotRefusal.displayChangeInProgress.message))
        gate.relabel(.restoring)
        let restoring = await coord.saveManually()
        XCTAssertEqual(restoring, .refused(message: SnapshotRefusal.restoring.message))
        gate.reopen(ifEpoch: epoch)
        let ok = await coord.saveManually()
        XCTAssertEqual(ok, .saved(windowCount: 3))
        let count = await cap.reasons.count
        XCTAssertEqual(count, 1)
    }

    /// Fix 1: a callback after the capture began (token taken) means nothing is written, nothing is
    /// learned and the save observer does not fire. Covers a plain close and a close-then-reopen.
    func testCallbackMidCaptureSavesNothing() async throws {
        for reopenBeforeSave in [false, true] {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("SnapshotSchedulerTests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = SnapshotStore(directory: dir)
            let gate = SnapshotGate()
            let learnedStore = LearnedLayoutStore()
            let saves = Counter()
            let capturer = StoreBackedCapturer(store: store, layout: layout(["b", "a"])) {
                let epoch = gate.closeForDisplayChange()
                if reopenBeforeSave { gate.reopen(ifEpoch: epoch) }
            }
            let coord = SnapshotCoordinator(capturer: capturer, gate: gate, learnedStore: learnedStore,
                                            liveLayout: { MonitorLayout(origins: [:]) })
            await coord.setSaveObserver { saves.bump() }

            let result = await coord.saveManually()
            XCTAssertEqual(result, .refused(message: SnapshotRefusal.displayChangeInProgress.message))
            let written = FileManager.default.fileExists(atPath: store.snapshotURL.path)
            XCTAssertFalse(written, "reopen: \(reopenBeforeSave)")
            let learned = await learnedStore.layout
            XCTAssertTrue(learned.origins.isEmpty)
            XCTAssertEqual(saves.value, 0)
        }
    }

    /// A callback after the file committed but before learning freezes the learned layout.
    func testCallbackBetweenWriteAndLearnFreezesLearning() async {
        let cap = FakeCapturer()
        let gate = SnapshotGate()
        let docked = layout(["a", "b"])
        let coord = SnapshotCoordinator(capturer: cap, gate: gate, liveLayout: { docked })
        await cap.setLayout(docked)
        _ = await coord.saveManually()

        await cap.setLayout(layout(["b", "a"]))
        await cap.setDuringCapture { gate.closeForDisplayChange() }
        await coord.runScheduledSnapshot()
        let learned = await coord.learnedLayout
        XCTAssertEqual(learned, docked)
    }

    func testLayoutLearnedOutsidePauseOnly() async {
        let cap = FakeCapturer()
        let gate = SnapshotGate()
        let docked = layout(["a", "b"])
        let live = LiveBox(docked)
        let coord = SnapshotCoordinator(capturer: cap, gate: gate, liveLayout: { live.value })
        await cap.setLayout(docked)
        _ = await coord.saveManually()
        let learned1 = await coord.learnedLayout
        XCTAssertEqual(learned1, docked)

        // Scrambled state while closed: never captured, never learned.
        await cap.setLayout(layout(["b", "a"]))
        gate.closeForDisplayChange()
        _ = await coord.saveManually()
        gate.relabel(.awaitingRestore)
        await coord.runScheduledSnapshot()
        let learned2 = await coord.learnedLayout
        XCTAssertEqual(learned2, docked)
        let count = await cap.reasons.count
        XCTAssertEqual(count, 1)
    }

    func testLayoutNotLearnedWhileUndocked() async {
        let cap = FakeCapturer()
        let docked = layout(["a", "b"])
        let live = LiveBox(docked)
        let coord = SnapshotCoordinator(capturer: cap, gate: SnapshotGate(), liveLayout: { live.value })
        await cap.setLayout(docked)
        _ = await coord.saveManually()

        live.value = layout(["a"])  // laptop-only
        await cap.setLayout(layout(["a"]))
        let r = await coord.saveManually()
        XCTAssertEqual(r, .refused(message: SnapshotRefusal.dockedSetAbsent.message))
        let learned = await coord.learnedLayout
        XCTAssertEqual(learned, docked)
        let count = await cap.reasons.count
        XCTAssertEqual(count, 1)
    }

    func testEmptyLayoutIsNeverLearned() async throws {
        let gate = SnapshotGate()
        let store = LearnedLayoutStore()
        let learnedEmpty = await store.learn(MonitorLayout(origins: [:]), ifGate: try XCTUnwrap(gate.token()))
        XCTAssertFalse(learnedEmpty)
        let learned = await store.layout
        XCTAssertTrue(learned.origins.isEmpty)
    }
}
