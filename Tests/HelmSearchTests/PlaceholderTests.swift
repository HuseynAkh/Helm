import XCTest
import HelmSearch

final class HelmSearchPlaceholderTests: XCTestCase {
    func testModuleIsAvailable() { XCTAssertEqual(HelmSearchModule.name, "HelmSearch") }
}
