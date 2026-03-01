import XCTest

final class HelmUITests: XCTestCase {

    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows.count > 0, "App should have at least one window")
    }
}
