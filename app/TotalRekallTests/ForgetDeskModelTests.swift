import XCTest
import AppKit
@testable import TotalRekall

@MainActor
final class ForgetDeskModelTests: XCTestCase {
    private func makeModel(forgets: @escaping () -> Void = {}, cancels: @escaping () -> Void = {}) -> ForgetDeskModel {
        ForgetDeskModel(deskName: "Studio", onForget: { forgets() }, onCancel: { cancels() })
    }

    func testTitleAndBodyCopy() {
        let model = makeModel()
        XCTAssertEqual(model.title, "Forget \u{201C}Studio\u{201D}?")
        XCTAssertEqual(model.body, "TotalRekall will stop restoring windows on this desk. "
                       + "It will ask you to name it again the next time you connect these monitors.")
    }

    func testCancelNeverForgets() {
        var forgets = 0, cancels = 0
        let model = makeModel(forgets: { forgets += 1 }, cancels: { cancels += 1 })
        model.cancel()
        model.cancel()   // Esc / close after the button: still once
        XCTAssertEqual(forgets, 0)
        XCTAssertEqual(cancels, 1)
    }

    func testForgetCallsForgetOnce() {
        var forgets = 0, cancels = 0
        let model = makeModel(forgets: { forgets += 1 }, cancels: { cancels += 1 })
        model.forget()
        model.forget()
        model.cancel()   // the window's close path after Forget must not count as a cancel
        XCTAssertEqual(forgets, 1)
        XCTAssertEqual(cancels, 0)
    }

    func testCancelThenForgetDoesNotForget() {
        var forgets = 0
        let model = makeModel(forgets: { forgets += 1 })
        model.cancel()
        model.forget()
        XCTAssertEqual(forgets, 0)
    }

    func testWindowFloatsAndClosingCancels() {
        var forgets = 0, cancels = 0
        let sut = ForgetDeskWindowController()
        sut.show(model: makeModel(forgets: { forgets += 1 }, cancels: { cancels += 1 }))
        XCTAssertTrue(sut.isShown)
        XCTAssertEqual(sut.windowLevel, .floating)
        sut.close()
        XCTAssertEqual(forgets, 0)
        XCTAssertEqual(cancels, 1)
    }
}
