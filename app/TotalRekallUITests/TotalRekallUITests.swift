import XCTest

final class TotalRekallUITests: XCTestCase {
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["TotalRekall"].exists)
    }
}
