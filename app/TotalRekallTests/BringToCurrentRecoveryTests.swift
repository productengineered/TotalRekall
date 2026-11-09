import XCTest
@testable import TotalRekall

/// Regression tests for bug 34: Terminal window (empty title) ax-unreachable after bring-to-current.

/// Bring-to-current succeeds; the move back to the origin desktop can be made to fail.
private actor ReturnTripSpaces: WindowSpaceMoving {
    var windowSpace: [UInt32: UInt64]
    let current: UInt64
    let failMovesTo: Set<UInt64>
    private(set) var moves: [UInt64] = []

    init(windowSpace: [UInt32: UInt64], current: UInt64, failMovesTo: Set<UInt64> = []) {
        self.windowSpace = windowSpace
        self.current = current
        self.failMovesTo = failMovesTo
    }

    func spaceIDs(forWindows windowIDs: [CGWindowID]) async throws -> [UInt64] {
        windowIDs.compactMap { windowSpace[$0] }
    }

    func moveWindows(_ windowIDs: [CGWindowID], toSpaceID spaceID: UInt64) async throws {
        moves.append(spaceID)
        if failMovesTo.contains(spaceID) { throw SpaceBridgeError.moveNotConfirmed(timeoutMS: 1500) }
        for id in windowIDs { windowSpace[id] = spaceID }
    }

    func currentSpaceID(onDisplayContaining spaceID: UInt64) async throws -> UInt64? { current }
}

private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var slept: [Int] { lock.withLock { values } }
    func record(_ ms: Int) { lock.withLock { values.append(ms) } }
}

final class BringToCurrentRecoveryTests: XCTestCase {
    private let target = SnapshotFrame(x: 100, y: 200, width: 800, height: 600)
    private let stale = SnapshotFrame(x: 0, y: 0, width: 300, height: 300)

    private func planned(_ wid: UInt32, title: String = "") -> PlannedWindow {
        PlannedWindow(snapshotID: UUID(), windowID: wid, bundleID: "com.apple.Terminal", appName: "Terminal",
                      title: title, action: .bringToCurrent(returnSpaceID: 20, frame: target))
    }

    // MARK: Failure path returns the window to its original desktop

    func testUnreachableWindowIsReturnedToOriginAndConfirmed() async {
        let spaces = ReturnTripSpaces(windowSpace: [152_435: 5], current: 10)
        let sut = WindowRestorer(spaces: spaces, writer: FakeAXWriter(element: nil), sleep: { _ in })
        let result = await sut.execute(RestorePlan(windows: [planned(152_435)], capability: .full)).first

        XCTAssertEqual(result?.status, .axUnreachable)
        XCTAssertTrue(result?.detail?.contains("returned to original desktop (confirmed)") ?? false)
        let final = await spaces.windowSpace[152_435]
        XCTAssertEqual(final, 5, "window must end on its original desktop")
        let moves = await spaces.moves
        XCTAssertEqual(moves, [10, 5])
    }

    func testUnconfirmedReturnTripIsFailedNotUnreachable() async {
        // Bring to 10 succeeds, the move back to 5 never confirms: the window is stranded, so the
        // result must be `failed` (raises attention), never the quiet ax-unreachable.
        let spaces = ReturnTripSpaces(windowSpace: [152_435: 5], current: 10, failMovesTo: [5])
        let sut = WindowRestorer(spaces: spaces, writer: FakeAXWriter(element: nil), sleep: { _ in })
        let result = await sut.execute(RestorePlan(windows: [planned(152_435)], capability: .full)).first

        XCTAssertEqual(result?.status, .failed)
        XCTAssertTrue(result?.detail?.contains("return to original desktop unconfirmed") ?? false)
        let summary = RestoreSummary(results: [result].compactMap { $0 }, date: Date())
        XCTAssertTrue(summary.needsAttention)
    }

    // MARK: Longer, bounded re-acquire after the Space move

    func testReacquireAfterBringToCurrentWaitsLongerThanTheOldHalfSecond() async {
        // The old fixed poll gave up after 11 attempts (0...500 ms every 50 ms). AX lagging the move
        // by ~800 ms must now still be re-acquired.
        let el = FakeAXElement(start: stale)
        let writer = FakeAXWriter(element: el, missesBeforeFound: 5)
        let recorder = SleepRecorder()
        let spaces = ReturnTripSpaces(windowSpace: [7: 5], current: 10)
        let sut = WindowRestorer(spaces: spaces, writer: writer, sleep: { recorder.record($0) })
        let result = await sut.execute(RestorePlan(windows: [planned(7, title: "zsh")], capability: .full)).first

        XCTAssertEqual(result?.status, .moved)
        XCTAssertEqual(writer.acquireCalls, 6)
        XCTAssertEqual(Array(recorder.slept.prefix(5)), [50, 100, 200, 400, 400])
        let final = await spaces.windowSpace[7]
        XCTAssertEqual(final, 20)
    }

    func testSpaceMoveBackoffIsBounded() {
        let timing = FrameWriteTiming.standard
        let steps = VerifiedFrameWriter.spaceMoveBackoff(timing)
        XCTAssertEqual(steps, [50, 100, 200, 400, 400, 400])
        XCTAssertGreaterThanOrEqual(steps.reduce(0, +), timing.reacquireAfterSpaceMoveMS)
        XCTAssertLessThan(steps.reduce(0, +), timing.reacquireAfterSpaceMoveMS + timing.reacquireBackoffMaxStepMS)
        XCTAssertTrue(steps.allSatisfy { $0 <= timing.reacquireBackoffMaxStepMS })
        var zero = timing
        zero.pollIntervalMS = 0
        XCTAssertEqual(VerifiedFrameWriter.spaceMoveBackoff(zero), [])
    }

    func testFullyUnreachableWindowStopsAfterBackoff() async {
        let writer = FakeAXWriter(element: nil)
        let spaces = ReturnTripSpaces(windowSpace: [7: 5], current: 10)
        _ = await WindowRestorer(spaces: spaces, writer: writer, sleep: { _ in })
            .execute(RestorePlan(windows: [planned(7)], capability: .full))
        XCTAssertEqual(writer.acquireCalls, 1 + VerifiedFrameWriter.spaceMoveBackoff(.standard).count)
    }

    // MARK: Plan: untitled windows AX never matched are not brought to current

    private let topology = [
        DisplaySpaces(serial: .builtin, spaces: [SpaceInfo(id64: 10, type: 0), SpaceInfo(id64: 11, type: 0)])
    ]

    private func saved(title: String, axVisible: Bool?) -> WindowSnapshot {
        WindowSnapshot(
            id: UUID(), bundleID: "com.apple.Terminal", appName: "Terminal", windowID: 152_435, windowTitle: title,
            windowIndex: 0, displayFingerprint: nil, displayIndex: 0, panelSerial: "builtin", spaceOrdinal: 2,
            spaceUUID: nil, spaceIndex: 1, frame: target, isFullscreen: false, isMinimized: false, zOrder: 0,
            sticky: nil, axVisible: axVisible)
    }

    private func plannedAction(_ s: WindowSnapshot, frame: SnapshotFrame, spaces: [UInt64]) -> PlannedAction {
        let live = LiveWindowState(windowID: 152_435, frame: frame, axVisible: false, spaceIDs: spaces)
        return RestorePlan.build(snapshot: [s], live: [live], topology: topology, capability: .full).windows[0].action
    }

    func testUntitledNeverAXMatchedIsSkippedWithReason() {
        for axVisible in [false, nil] as [Bool?] {
            let s = saved(title: "", axVisible: axVisible)
            // Hidden on the wrong desktop, and hidden on the right desktop with a wrong frame.
            XCTAssertEqual(plannedAction(s, frame: stale, spaces: [10]), .skip(.untitledNoAXMatch))
            XCTAssertEqual(plannedAction(s, frame: stale, spaces: [11]), .skip(.untitledNoAXMatch))
        }
    }

    func testUntitledButAXMatchedAtCaptureIsStillBroughtToCurrent() {
        XCTAssertEqual(plannedAction(saved(title: "", axVisible: true), frame: stale, spaces: [10]),
                       .bringToCurrent(returnSpaceID: 11, frame: target))
    }

    func testTitledWindowIsStillBroughtToCurrent() {
        XCTAssertEqual(plannedAction(saved(title: "zsh", axVisible: false), frame: stale, spaces: [10]),
                       .bringToCurrent(returnSpaceID: 11, frame: target))
    }

    func testUntitledSkipIsLoggedWithoutAttention() {
        let status = RestoreStatus.skipped(.untitledNoAXMatch)
        XCTAssertEqual(status.logValue, "skipped:untitled-no-ax-match")
        XCTAssertEqual(RestoreStatus(logValue: status.logValue), status)
        let result = RestoreWindowResult(snapshotID: UUID(), windowID: 1, bundleID: "b", appName: "a", title: "",
                                         status: status)
        XCTAssertFalse(RestoreSummary(results: [result], date: Date()).needsAttention)
    }
}
