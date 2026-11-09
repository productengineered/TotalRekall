import XCTest
@testable import TotalRekall

@MainActor
final class StatusIconStateTests: XCTestCase {
    @MainActor private final class Probe {
        var reduceMotion = false
        var changes = 0
    }

    private let probe = Probe()
    private var reduceMotion: Bool {
        get { probe.reduceMotion }
        set { probe.reduceMotion = newValue }
    }
    private var changes: Int { probe.changes }
    private var sut: StatusIconAnimator!

    override func setUp() {
        super.setUp()
        let probe = self.probe
        probe.reduceMotion = false
        probe.changes = 0
        sut = StatusIconAnimator(reduceMotion: { probe.reduceMotion },
                                 observeSystem: false,
                                 onChange: { probe.changes += 1 })
    }

    override func tearDown() {
        sut.shutDown()
        sut = nil
        super.tearDown()
    }

    func testIdleHasNoTimer() {
        XCTAssertEqual(sut.mode, .idle)
        XCTAssertFalse(sut.isTimerActive)
    }

    func testWorkingStartsAnimationAndTimer() {
        sut.setWorking(true)
        XCTAssertEqual(sut.mode, .animating)
        XCTAssertTrue(sut.isTimerActive)
    }

    func testTickAdvancesAndWrapsFrames() {
        sut.setWorking(true)
        for _ in 0..<StatusIcon.workingFrameCount { sut.tick() }
        XCTAssertEqual(sut.frame, 0)
        sut.tick()
        XCTAssertEqual(sut.frame, 1)
    }

    func testRepeatedWorkingKeepsSingleTimer() {
        sut.setWorking(true)
        let before = changes
        sut.setWorking(true)
        XCTAssertTrue(sut.isTimerActive)
        XCTAssertEqual(changes, before)
    }

    /// Success, attention and failure all reach the animator as "not working".
    func testStopsOnEveryTerminalOutcome() {
        for _ in ["success", "attention", "failure"] {
            sut.setWorking(true)
            sut.tick()
            sut.setWorking(false)
            XCTAssertEqual(sut.mode, .idle)
            XCTAssertFalse(sut.isTimerActive)
            XCTAssertEqual(sut.frame, 0)
        }
    }

    func testTickAfterStopDoesNothing() {
        sut.setWorking(true)
        sut.setWorking(false)
        let before = changes
        sut.tick()
        XCTAssertEqual(changes, before)
        XCTAssertEqual(sut.frame, 0)
    }

    func testReduceMotionShowsStaticGlyphWithoutTimer() {
        reduceMotion = true
        sut.reduceMotionMayHaveChanged()
        sut.setWorking(true)
        XCTAssertEqual(sut.mode, .staticWorking)
        XCTAssertFalse(sut.isTimerActive)
        sut.tick()
        XCTAssertEqual(sut.frame, 0)
    }

    func testReduceMotionToggledMidRestoreSwitchesMode() {
        sut.setWorking(true)
        XCTAssertTrue(sut.isTimerActive)
        reduceMotion = true
        sut.reduceMotionMayHaveChanged()
        XCTAssertEqual(sut.mode, .staticWorking)
        XCTAssertFalse(sut.isTimerActive)
        reduceMotion = false
        sut.reduceMotionMayHaveChanged()
        XCTAssertEqual(sut.mode, .animating)
        XCTAssertTrue(sut.isTimerActive)
    }

    func testShutDownInvalidatesTimer() {
        sut.setWorking(true)
        sut.shutDown()
        XCTAssertFalse(sut.isTimerActive)
        XCTAssertEqual(sut.mode, .idle)
        sut.setWorking(false)
        XCTAssertFalse(sut.isTimerActive)
    }

    func testBadgeMappingKeepsWorkingAndAttention() {
        XCTAssertEqual(StatusIcon.badge(iconName: "exclamationmark.triangle", animates: true), .attention)
        XCTAssertEqual(StatusIcon.badge(iconName: "bear", animates: true), .working)
        XCTAssertEqual(StatusIcon.badge(iconName: "bear", animates: false), .none)
    }
}
