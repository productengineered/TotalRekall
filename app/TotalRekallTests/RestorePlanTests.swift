import XCTest
@testable import TotalRekall

final class RestorePlanTests: XCTestCase {
    private let frameA = SnapshotFrame(x: 100, y: 100, width: 800, height: 600)
    private let frameB = SnapshotFrame(x: 400, y: 300, width: 800, height: 600)

    // Panel "builtin": spaces 10, 11 (user), 12 (fullscreen). Panel "EXT1": spaces 20, 21.
    private var topology: [DisplaySpaces] {
        [
            DisplaySpaces(serial: .builtin, spaces: [SpaceInfo(id64: 10, type: 0), SpaceInfo(id64: 11, type: 0),
                                                     SpaceInfo(id64: 12, type: 4)]),
            DisplaySpaces(serial: .panel("EXT1"), spaces: [SpaceInfo(id64: 20, type: 0), SpaceInfo(id64: 21, type: 0)])
        ]
    }

    private func saved(_ wid: UInt32?, panel: String? = "builtin", ordinal: Int? = 1,
                       frame: SnapshotFrame? = nil, minimized: Bool = false, fullscreen: Bool = false,
                       sticky: Bool? = nil) -> WindowSnapshot {
        WindowSnapshot(
            id: UUID(), bundleID: "com.example.app", appName: "App", windowID: wid, windowTitle: "w\(wid ?? 0)",
            windowIndex: 0, displayFingerprint: nil, displayIndex: 0, panelSerial: panel, spaceOrdinal: ordinal,
            spaceUUID: nil, spaceIndex: 0, frame: frame ?? frameA, isFullscreen: fullscreen,
            isMinimized: minimized, zOrder: 0, sticky: sticky)
    }

    private func live(_ wid: UInt32, frame: SnapshotFrame? = nil, ax: Bool = true, spaces: [UInt64] = [10]) -> LiveWindowState {
        LiveWindowState(windowID: wid, frame: frame ?? frameA, axVisible: ax, spaceIDs: spaces)
    }

    private func action(_ s: WindowSnapshot, _ l: [LiveWindowState], capability: SpaceBridgeCapability = .full) -> PlannedAction {
        RestorePlan.build(snapshot: [s], live: l, topology: topology, capability: capability).windows[0].action
    }

    func testAlreadyCorrect() {
        XCTAssertEqual(action(saved(1), [live(1)]), .alreadyCorrect)
    }

    func testFrameWithinToleranceIsAlreadyCorrect() {
        let nudged = SnapshotFrame(x: 101.5, y: 99, width: 800, height: 601)
        XCTAssertEqual(action(saved(1), [live(1, frame: nudged)]), .alreadyCorrect)
    }

    func testFrameFixWhenOnRightDesktopButWrongFrame() {
        XCTAssertEqual(action(saved(1), [live(1, frame: frameB)]), .frameFix(frameA))
    }

    func testSpaceMoveWithFrameFixWhenOnWrongDesktop() {
        let a = action(saved(1, ordinal: 2), [live(1, frame: frameB, spaces: [10])])
        XCTAssertEqual(a, .moveSpace(spaceID: 11, desktop: DesktopKey(panelSerial: "builtin", ordinal: 2), frame: frameA))
    }

    func testSpaceMoveWithoutFrameFixWhenFrameCorrect() {
        let a = action(saved(1, ordinal: 2), [live(1, spaces: [10])])
        XCTAssertEqual(a, .moveSpace(spaceID: 11, desktop: DesktopKey(panelSerial: "builtin", ordinal: 2), frame: nil))
    }

    func testSpaceMoveAcrossPanels() {
        let a = action(saved(1, panel: "EXT1", ordinal: 1), [live(1, spaces: [10])])
        XCTAssertEqual(a, .moveSpace(spaceID: 20, desktop: DesktopKey(panelSerial: "EXT1", ordinal: 1), frame: nil))
    }

    func testBringToCurrentForHiddenWindowWithWrongFrame() {
        let a = action(saved(1), [live(1, frame: frameB, ax: false, spaces: [10])])
        XCTAssertEqual(a, .bringToCurrent(returnSpaceID: 10, frame: frameA))
    }

    func testBringToCurrentWhenHiddenAndOnWrongDesktopWithWrongFrame() {
        let a = action(saved(1, ordinal: 2), [live(1, frame: frameB, ax: false, spaces: [10])])
        XCTAssertEqual(a, .bringToCurrent(returnSpaceID: 11, frame: frameA))
    }

    func testHiddenWindowAlreadyCorrectIsLeftAlone() {
        XCTAssertEqual(action(saved(1), [live(1, ax: false)]), .alreadyCorrect)
    }

    // MARK: Skips

    func testSkipMinimizedByFlagAndByReason() {
        XCTAssertEqual(action(saved(1, minimized: true), [live(1)]), .skip(.minimized))
        var s = saved(1)
        s.skipReason = .minimized
        XCTAssertEqual(action(s, [live(1)]), .skip(.minimized))
    }

    func testSkipFullscreen() {
        XCTAssertEqual(action(saved(1, ordinal: nil, fullscreen: true), [live(1)]), .skip(.fullscreen))
    }

    func testSkipStickyFromSnapshotAndFromLiveSpaces() {
        XCTAssertEqual(action(saved(1, sticky: true), [live(1)]), .skip(.sticky))
        XCTAssertEqual(action(saved(1), [live(1, spaces: [10, 11])]), .skip(.sticky))
    }

    func testSkipDesktopMissingLeavesWindowInPlace() {
        let a = action(saved(1, panel: "EXT1", ordinal: 5), [live(1, frame: frameB, spaces: [20])])
        XCTAssertEqual(a, .skip(.desktopMissing))
    }

    func testSkipPanelNotConnected() {
        XCTAssertEqual(action(saved(1, panel: "GONE", ordinal: 1), [live(1)]), .skip(.panelNotConnected))
    }

    func testSkipNotFoundWhenWindowIDNotLive() {
        XCTAssertEqual(action(saved(1), []), .skip(.notFound))
        XCTAssertEqual(action(saved(nil), [live(1)]), .skip(.notFound))
    }

    func testMatchingIsByWindowIDOnly() {
        // Same title/app but a different id must not match.
        var s = saved(1)
        s.windowTitle = "same"
        let other = live(2)
        XCTAssertEqual(action(s, [other]), .skip(.notFound))
    }

    // MARK: positionOnly

    func testPositionOnlyPlansNoSpaceMoves() {
        let cap = SpaceBridgeCapability.positionOnly(reason: "missing symbol")
        let snapshot = [saved(1, ordinal: 2, frame: frameA), saved(2, panel: "EXT1", ordinal: 1, frame: frameA),
                        saved(3, frame: frameA)]
        let lives = [live(1, frame: frameB, spaces: [10]), live(2, spaces: [10]), live(3, frame: frameB, ax: false)]
        let plan = RestorePlan.build(snapshot: snapshot, live: lives, topology: topology, capability: cap)
        XCTAssertTrue(plan.spaceMoveGroups.isEmpty)
        for w in plan.windows {
            switch w.action {
            case .moveSpace, .bringToCurrent: XCTFail("positionOnly must not plan Space moves: \(w.action)")
            default: break
            }
        }
        XCTAssertEqual(plan.windows[0].action, .frameFix(frameA))
        XCTAssertEqual(plan.windows[1].action, .alreadyCorrect)
        XCTAssertEqual(plan.windows[2].action, .frameFix(frameA), "hidden window is attempted via AX and reported unreachable")
    }

    func testPositionOnlyStillSkipsDesktopMissing() {
        let cap = SpaceBridgeCapability.positionOnly(reason: "x")
        XCTAssertEqual(action(saved(1, ordinal: 9), [live(1)], capability: cap), .skip(.desktopMissing))
    }

    // MARK: Grouping

    func testSpaceMovesGroupedByTargetDesktop() {
        let snapshot = [saved(5, ordinal: 2), saved(3, ordinal: 2), saved(9, panel: "EXT1", ordinal: 2),
                        saved(7, ordinal: 2)]
        let lives = [live(5, spaces: [10]), live(3, spaces: [10]), live(9, spaces: [10]), live(7, spaces: [11])]
        let plan = RestorePlan.build(snapshot: snapshot, live: lives, topology: topology, capability: .full)
        XCTAssertEqual(plan.spaceMoveGroups, [
            SpaceMoveGroup(desktop: DesktopKey(panelSerial: "EXT1", ordinal: 2), spaceID: 21, windowIDs: [9]),
            SpaceMoveGroup(desktop: DesktopKey(panelSerial: "builtin", ordinal: 2), spaceID: 11, windowIDs: [3, 5])
        ])
        XCTAssertTrue(plan.hasWork)
    }

    func testHasWorkFalseWhenEverythingCorrectOrSkipped() {
        let plan = RestorePlan.build(snapshot: [saved(1), saved(2, minimized: true)], live: [live(1)],
                                     topology: topology, capability: .full)
        XCTAssertFalse(plan.hasWork)
    }
}
