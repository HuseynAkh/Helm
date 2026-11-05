// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore

final class CloudContractTests: XCTestCase {
    func testCloudMetadataRoundTripsAndDefaultsForOlderPayloads() throws {
        let entry = FileEntry(url: URL(fileURLWithPath: "/placeholder"), cloudAvailability: .evicted)
        let data = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(FileEntry.self, from: data), entry)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "cloudAvailability")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(FileEntry.self, from: legacy).cloudAvailability, .unknown)
        XCTAssertEqual(FileEntry(url: entry.url).cloudAvailability, .unknown)
    }
}
