import XCTest
import HelmTestKit

final class HelmTestKitPlaceholderTests: XCTestCase {
    func testModuleIsAvailable() { XCTAssertEqual(HelmTestKitModule.name, "HelmTestKit") }
}
