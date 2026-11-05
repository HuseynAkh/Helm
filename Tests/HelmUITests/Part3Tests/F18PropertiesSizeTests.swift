// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmUI

final class F18PropertiesAdapterTests: XCTestCase {
    private let package = FileEntry(url: URL(fileURLWithPath: "/Tool.app"), kind: .package, size: 4096)
    func testPackageAndMixedSizeQualification() {
        XCTAssertEqual(PropertiesViewModel(entries: [package]).size, "Calculating contents size")
        let file = FileEntry(url: URL(fileURLWithPath: "/file"), size: 12)
        XCTAssertEqual(PropertiesViewModel(entries: [file, package]).size, "12 bytes (known contents only)")
        XCTAssertEqual(PropertiesViewModel(entries: [file]).size, "12 bytes")
    }
    func testTrustedRecursiveTotalAndIncompleteStates() {
        let total = InspectorSizeTotal(bytes: 200_000_000, itemCount: 42)
        XCTAssertEqual(PropertiesViewModel(entries: [package], contentsSize: .final(total)).size, "200000000 bytes")
        XCTAssertEqual(PropertiesViewModel(entries: [package], contentsSize: .partial(total)).size, "200000000 bytes (known contents only)")
        XCTAssertEqual(PropertiesViewModel(entries: [package], contentsSize: .unavailable).size, "Unknown")
        XCTAssertEqual(PropertiesViewModel(entries: [package], contentsSize: .final(InspectorSizeTotal(bytes: .max, itemCount: 1, overflowed: true))).size, "Size exceeds supported total")
    }
}
