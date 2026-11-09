import XCTest
@testable import TotalRekall

final class SwapDetectorTests: XCTestCase {
    // Real serials/origins from a layout baseline measured on real hardware (2026-11-04).
    private let p304 = "FAKESERIAL0001"
    private let p204 = "FAKESERIAL0002"

    private func layout(_ a: (Int, Int), _ b: (Int, Int), builtin: (Int, Int) = (2560, 701)) -> MonitorLayout {
        MonitorLayout(origins: [
            p304: .init(x: a.0, y: a.1),
            p204: .init(x: b.0, y: b.1),
            "builtin": .init(x: builtin.0, y: builtin.1)
        ])
    }

    func testCorrectLayoutIsCorrect() {
        let learned = layout((-2560, 0), (0, 0))
        XCTAssertEqual(SwapDetector.detect(learned: learned, live: learned), .correct)
    }

    func testSwappedPanelsProduceFullLearnedPlan() {
        let learned = layout((-2560, 0), (0, 0))
        let live = layout((0, 0), (-2560, 0))
        XCTAssertEqual(SwapDetector.detect(learned: learned, live: live),
                       .swapped(LayoutFixPlan(targets: learned.origins)))
    }

    func testEdgeSnapWithinToleranceIsCorrect() {
        let learned = layout((-2560, 0), (0, 0), builtin: (2560, 691))
        let live = layout((-2560, 0), (0, 0), builtin: (2560, 695))
        XCTAssertEqual(SwapDetector.detect(learned: learned, live: live), .correct)
    }

    func testBeyondToleranceIsSwapped() {
        let learned = layout((-2560, 0), (0, 0))
        let live = layout((-2560, 0), (0, 40))
        guard case .swapped = SwapDetector.detect(learned: learned, live: live) else {
            return XCTFail("expected swapped")
        }
    }

    func testUnreadableSerialIsUnknown() {
        let learned = layout((-2560, 0), (0, 0))
        guard case .unknown = SwapDetector.detect(learned: learned, live: learned, hasUnreadableSerial: true) else {
            return XCTFail("expected unknown")
        }
    }

    func testPanelSetMismatchIsUnknown() {
        let learned = layout((-2560, 0), (0, 0))
        var live = learned
        live.origins.removeValue(forKey: p204)
        guard case .unknown = SwapDetector.detect(learned: learned, live: live) else {
            return XCTFail("expected unknown")
        }
    }

    func testEmptyLearnedIsUnknown() {
        let live = layout((0, 0), (-2560, 0))
        guard case .unknown = SwapDetector.detect(learned: MonitorLayout(origins: [:]), live: live) else {
            return XCTFail("expected unknown")
        }
    }

    // MARK: MonitorFixer

    private final class Box: @unchecked Sendable {
        var reads: [LiveLayoutReading]
        var applied: [[UInt32: MonitorLayout.Origin]] = []
        var events: [String] = []
        init(_ r: [LiveLayoutReading]) { reads = r }
    }
    private struct Reader: LayoutReading {
        let box: Box
        func readLayout() -> LiveLayoutReading { box.reads.count > 1 ? box.reads.removeFirst() : box.reads[0] }
    }
    private struct Applier: DisplayConfigApplying {
        let box: Box
        func apply(origins: [UInt32: MonitorLayout.Origin]) -> Bool { box.events.append("apply"); box.applied.append(origins); return true }
    }
    private struct Suppressor: SelfChangeSuppressor {
        let box: Box
        func beginSelfChange() { box.events.append("begin") }
        func endSelfChange() { box.events.append("end") }
    }

    private func reading(_ l: MonitorLayout) -> LiveLayoutReading {
        LiveLayoutReading(layout: l, displayIDBySerial: [p304: 1, p204: 2, "builtin": 3], hasUnreadableSerial: false)
    }

    func testFixerAppliesInsideSuppressionAndVerifies() {
        let learned = layout((-2560, 0), (0, 0))
        let box = Box([reading(layout((0, 0), (-2560, 0))), reading(learned)])
        let fixer = MonitorFixer(reader: Reader(box: box), applier: Applier(box: box),
                                 suppressor: Suppressor(box: box), settle: {})
        XCTAssertEqual(fixer.fix(learned: learned), .verified)
        XCTAssertEqual(box.events, ["begin", "apply", "end"])
        XCTAssertEqual(box.applied.first?[1], .init(x: -2560, y: 0))
        XCTAssertEqual(box.applied.first?[2], .init(x: 0, y: 0))
    }

    func testFixerReportsUnverifiedWhenStillWrong() {
        let learned = layout((-2560, 0), (0, 0))
        let box = Box([reading(layout((0, 0), (-2560, 0)))])
        let fixer = MonitorFixer(reader: Reader(box: box), applier: Applier(box: box), settle: {})
        guard case .unverified = fixer.fix(learned: learned) else { return XCTFail("expected unverified") }
    }

    func testFixerSkipsWhenCorrectOrUnknown() {
        let learned = layout((-2560, 0), (0, 0))
        let box = Box([reading(learned)])
        let fixer = MonitorFixer(reader: Reader(box: box), applier: Applier(box: box), settle: {})
        XCTAssertEqual(fixer.fix(learned: learned), .alreadyInOrder)
        XCTAssertTrue(box.applied.isEmpty)
        let bad = LiveLayoutReading(layout: learned, displayIDBySerial: [:], hasUnreadableSerial: true)
        let box2 = Box([bad])
        let fixer2 = MonitorFixer(reader: Reader(box: box2), applier: Applier(box: box2), settle: {})
        guard case .skipped = fixer2.fix(learned: learned) else { return XCTFail("expected skipped") }
        XCTAssertTrue(box2.applied.isEmpty)
    }
}
