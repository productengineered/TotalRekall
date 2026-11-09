import XCTest
@testable import TotalRekall

final class FakeAXElement: AXWindowElement {
    var frame: SnapshotFrame
    var calls: [String] = []
    var posCountToAccept: Int
    var enhancedUIOn: Bool
    var enhancedUIEvents: [String] = []
    private var pendingSize = CGSize.zero
    private var posCount = 0

    init(start: SnapshotFrame, acceptAtPositionCall: Int = 1, enhancedUI: Bool = false) {
        frame = start
        posCountToAccept = acceptAtPositionCall
        enhancedUIOn = enhancedUI
    }

    func setSize(_ size: CGSize) -> Bool { calls.append("size"); pendingSize = size; return true }
    func setPosition(_ point: CGPoint) -> Bool {
        calls.append("pos")
        posCount += 1
        if posCount >= posCountToAccept {
            frame = SnapshotFrame(x: point.x, y: point.y, width: pendingSize.width, height: pendingSize.height)
        }
        return true
    }
    func readFrame() -> SnapshotFrame? { frame }
    func disableEnhancedUI() -> Bool {
        guard enhancedUIOn else { return false }
        enhancedUIEvents.append("off")
        return true
    }
    func restoreEnhancedUI() { enhancedUIEvents.append("on") }
}

final class FakeAXWriter: AXFrameWriter, @unchecked Sendable {
    var element: FakeAXElement?
    var missesBeforeFound: Int
    private(set) var acquireCalls = 0

    init(element: FakeAXElement?, missesBeforeFound: Int = 0) {
        self.element = element
        self.missesBeforeFound = missesBeforeFound
    }

    func acquire(windowID: UInt32) -> AXWindowElement? {
        acquireCalls += 1
        if acquireCalls <= missesBeforeFound { return nil }
        return element
    }
}

actor FakeSpaces: WindowSpaceMoving {
    var windowSpace: [UInt32: UInt64]
    let current: UInt64
    var stuckAlways: Set<UInt32> = []
    var stuckInGroup: Set<UInt32> = []
    private(set) var moves: [(ids: [UInt32], to: UInt64)] = []

    init(windowSpace: [UInt32: UInt64], current: UInt64) {
        self.windowSpace = windowSpace
        self.current = current
    }

    func setStuck(always: Set<UInt32> = [], inGroup: Set<UInt32> = []) {
        stuckAlways = always
        stuckInGroup = inGroup
    }

    func spaceIDs(forWindows windowIDs: [CGWindowID]) async throws -> [UInt64] {
        windowIDs.compactMap { windowSpace[$0] }
    }

    func moveWindows(_ windowIDs: [CGWindowID], toSpaceID spaceID: UInt64) async throws {
        moves.append((windowIDs, spaceID))
        var unconfirmed = false
        for id in windowIDs {
            if stuckAlways.contains(id) || (windowIDs.count > 1 && stuckInGroup.contains(id)) {
                unconfirmed = true
            } else {
                windowSpace[id] = spaceID
            }
        }
        if unconfirmed { throw SpaceBridgeError.moveNotConfirmed(timeoutMS: 1500) }
    }

    func currentSpaceID(onDisplayContaining spaceID: UInt64) async throws -> UInt64? { current }
}

final class WindowRestorerTests: XCTestCase {
    private let target = SnapshotFrame(x: 100, y: 200, width: 800, height: 600)
    private let stale = SnapshotFrame(x: 0, y: 0, width: 300, height: 300)
    private let desktop = DesktopKey(panelSerial: "PANEL", ordinal: 2)

    private func planned(_ wid: UInt32, _ action: PlannedAction) -> PlannedWindow {
        PlannedWindow(snapshotID: UUID(), windowID: wid, bundleID: "com.example", appName: "App",
                      title: "T\(wid)", action: action)
    }

    private func restorer(_ spaces: FakeSpaces, _ writer: FakeAXWriter) -> WindowRestorer {
        WindowRestorer(spaces: spaces, writer: writer, sleep: { _ in })
    }

    func testUnverifiedFrameRetriesInPositionSizePositionOrder() async {
        let el = FakeAXElement(start: stale, acceptAtPositionCall: Int.max, enhancedUI: true)
        let plan = RestorePlan(windows: [planned(1, .frameFix(target))], capability: .full)
        let results = await restorer(FakeSpaces(windowSpace: [1: 5], current: 5), FakeAXWriter(element: el)).execute(plan)

        XCTAssertEqual(results.first?.status, .movedUnverified)
        XCTAssertTrue(results.first?.detail?.contains("actual (0,0 300x300)") ?? false)
        let retry = ["pos", "size", "pos"]
        XCTAssertEqual(el.calls, ["size", "pos", "size"] + retry + retry + retry)
        XCTAssertEqual(el.enhancedUIEvents, ["off", "on"])
    }

    func testFrameVerifiedAfterOneRetryIsMoved() async {
        let el = FakeAXElement(start: stale, acceptAtPositionCall: 2)
        let plan = RestorePlan(windows: [planned(1, .frameFix(target))], capability: .full)
        let results = await restorer(FakeSpaces(windowSpace: [1: 5], current: 5), FakeAXWriter(element: el)).execute(plan)

        XCTAssertEqual(results.first?.status, .moved)
        XCTAssertEqual(el.calls.count, 6)
    }

    func testBringToCurrentMovesToCurrentThenFixesFrameThenReturns() async {
        let el = FakeAXElement(start: stale)
        let writer = FakeAXWriter(element: el, missesBeforeFound: 2)
        let spaces = FakeSpaces(windowSpace: [7: 5], current: 10)
        let plan = RestorePlan(windows: [planned(7, .bringToCurrent(returnSpaceID: 20, frame: target))], capability: .full)
        let results = await restorer(spaces, writer).execute(plan)

        XCTAssertEqual(results.first?.status, .moved)
        let moves = await spaces.moves
        XCTAssertEqual(moves.map(\.to), [10, 20])
        XCTAssertEqual(writer.acquireCalls, 3)
        let final = await spaces.windowSpace[7]
        XCTAssertEqual(final, 20)
    }

    func testAXUnreachableAfterBringToCurrentMovesWindowBack() async {
        let spaces = FakeSpaces(windowSpace: [7: 5], current: 10)
        let plan = RestorePlan(windows: [planned(7, .bringToCurrent(returnSpaceID: 20, frame: target))], capability: .full)
        let results = await restorer(spaces, FakeAXWriter(element: nil)).execute(plan)

        XCTAssertEqual(results.first?.status, .axUnreachable)
        let moves = await spaces.moves
        XCTAssertEqual(moves.map(\.to), [10, 5])
        let final = await spaces.windowSpace[7]
        XCTAssertEqual(final, 5)
    }

    func testGroupMoveRetriesUnconfirmedWindowsIndividuallyOnce() async {
        let spaces = FakeSpaces(windowSpace: [1: 5, 2: 5, 3: 5], current: 5)
        await spaces.setStuck(always: [3], inGroup: [2])
        let windows = [1, 2, 3].map { planned(UInt32($0), .moveSpace(spaceID: 30, desktop: desktop, frame: nil)) }
        let results = await restorer(spaces, FakeAXWriter(element: nil)).execute(RestorePlan(windows: windows, capability: .full))

        XCTAssertEqual(results.map(\.status), [.spaceMoved, .spaceMoved, .failed])
        let moves = await spaces.moves
        XCTAssertEqual(moves.map(\.ids), [[1, 2, 3], [2], [3]])
    }

    func testMoveSpaceWithFrameReacquiresAfterMoveAndSkipsPlanOnlyEntries() async {
        let el = FakeAXElement(start: stale)
        let writer = FakeAXWriter(element: el)
        let spaces = FakeSpaces(windowSpace: [1: 5], current: 5)
        let windows = [
            planned(1, .moveSpace(spaceID: 30, desktop: desktop, frame: target)),
            planned(2, .skip(.minimized)),
            planned(3, .alreadyCorrect)
        ]
        let results = await restorer(spaces, writer).execute(RestorePlan(windows: windows, capability: .full))

        XCTAssertEqual(results.map(\.status), [.moved, .skipped(.minimized), .alreadyCorrect])
        XCTAssertEqual(writer.acquireCalls, 1)
    }
}
