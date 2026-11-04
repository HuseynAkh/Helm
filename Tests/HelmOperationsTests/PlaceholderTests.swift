import XCTest
import HelmOperations

final class HelmOperationsPlaceholderTests: XCTestCase {
    func testModuleIsAvailable() { XCTAssertEqual(HelmOperationsModule.name, "HelmOperations") }
}
