import XCTest
import HelmAgent

/// The module links into its test target, and the fixtures folder travels with the test bundle.
final class HelmAgentModuleTests: XCTestCase {
    func testModuleLinksAndFixturesAreBundled() throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtures.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
