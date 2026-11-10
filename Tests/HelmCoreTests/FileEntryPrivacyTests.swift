import Foundation
import XCTest
import HelmCore

/// A folder macOS keeps private is recorded as such, and older saved entries still read back.
final class FileEntryPrivacyTests: XCTestCase {
    func testOlderPayloadsDecodeAsNotProtected() throws {
        let entry = FileEntry(url: URL(fileURLWithPath: "/Users/me/Movies/TV"), kind: .directory, isReadable: false)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertNotNil(payload.removeValue(forKey: "isPrivacyProtected"))
        let decoded = try JSONDecoder().decode(FileEntry.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertFalse(decoded.isPrivacyProtected)
        XCTAssertFalse(decoded.isReadable)
    }

    func testRoundTripKeepsTheFlag() throws {
        let entry = FileEntry(url: URL(fileURLWithPath: "/Users/me/Movies/TV"), kind: .directory, isReadable: false, isPrivacyProtected: true)
        let decoded = try JSONDecoder().decode(FileEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertTrue(decoded.isPrivacyProtected)
        XCTAssertEqual(decoded, entry)
        // An entry whose protection changed is a different entry, so the listing refreshes it.
        XCTAssertNotEqual(entry, FileEntry(url: entry.url, kind: .directory, isReadable: false))
        XCTAssertFalse(FileEntry(url: entry.url).isPrivacyProtected)
    }
}
