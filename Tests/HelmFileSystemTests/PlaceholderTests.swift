import XCTest
import HelmFileSystem

final class HelmFileSystemPlaceholderTests: XCTestCase {
    func testModuleIsAvailable() { XCTAssertEqual(HelmFileSystemModule.name, "HelmFileSystem") }
}
