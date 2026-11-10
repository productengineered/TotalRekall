import XCTest
@testable import TotalRekall

@MainActor
final class SetupWindowSizeTests: XCTestCase {
    private func makeModel() -> SetupViewModel {
        SetupViewModel.preview(.needsPermission(.firstRun))
    }

    func testMaxHeightIsTheLargestMeasuredVariant() {
        let variants = SetupWindowController.allVariants(paneName: "Accessibility")
        var calls = 0
        let result = SetupWindowController.maxHeight(of: variants) { _ in
            defer { calls += 1 }
            return CGFloat(calls * 10 + 50)
        }
        XCTAssertEqual(calls, variants.count)
        XCTAssertEqual(result, CGFloat((variants.count - 1) * 10 + 50))
        XCTAssertEqual(SetupWindowController.maxHeight(of: []) { _ in 99 }, 0)
    }

    func testAllStateAndReasonCombinationsAreMeasured() {
        XCTAssertEqual(SetupWindowController.allVariants(paneName: "Accessibility").count, 14)   // 5 permission states + 2 desk states, x 2 reasons
    }

    func testWindowHeightIsMaxAcrossVariantsAndNeverChangesAcrossStates() throws {
        let model = makeModel()
        let controller = SetupWindowController(model: model)
        controller.show()
        defer { controller.close() }

        let expected = SetupWindowController.fixedContentHeight(model: model)
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(controller.fixedContentHeight, expected)
        let initial = try XCTUnwrap(controller.windowFrame)

        let states: [SetupState] = [.needsPermission(.revoked), .waitingForGrant, .relaunchSuggested, .granted,
                                    .namingDesk(.docked), .namingDesk(.undocked), .needsPermission(.firstRun)]
        for state in states {
            model.forcePreviewState(state)
            controller.show()
            XCTAssertEqual(controller.windowFrame, initial, "frame changed for \(state)")
        }
    }
}
