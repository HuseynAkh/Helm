import XCTest
import HelmPersistence

final class HelmPersistencePlaceholderTests: XCTestCase {
    func testModuleIsAvailable() { XCTAssertEqual(HelmPersistenceModule.name, "HelmPersistence") }
}
