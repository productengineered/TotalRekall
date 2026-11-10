import XCTest
import AppKit
@testable import TotalRekall

/// The Save this desk? window opens while another app is frontmost (the dock-time cycle just ended), when an
/// accessory app's plain `makeKeyAndOrderFront` leaves it BEHIND that app's windows. In the user's real test
/// the window existed, on screen, at z-index 12 behind Chrome and cmux, so it was never seen.
@MainActor
final class DeskNameWindowControllerTests: XCTestCase {
    func testPromptWindowFloatsAboveOtherAppsAndIsShown() {
        let sut = DeskNameWindowController()
        let model = DeskNameModel(mode: .newDesk, initialName: "Desk 1", otherNames: [], onSave: { _ in }, onCancel: {})
        sut.show(model: model)
        defer { sut.close() }
        XCTAssertTrue(sut.isShown)
        XCTAssertEqual(sut.windowLevel, .floating, "must not sit at the normal level behind the frontmost app")
    }
}
