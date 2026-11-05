// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmPersistence

final class K34ViewDefaultsTests: XCTestCase {
    @MainActor func testMissingAndRestoredLocationDefaultsMatchCore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("options.json")
        let store = try await LocationViewOptionsStore(url: url)
        XCTAssertEqual(store.defaults.iconSize, ViewOptions().iconSize)
        XCTAssertEqual(store.defaults.iconSize, 96)
        XCTAssertEqual(store.options(for: .recent).iconSize, 96)
        try store.useAsDefaults(ViewOptions(iconSize: 512))
        try await store.flush()
        let restored = try await LocationViewOptionsStore(url: url)
        XCTAssertEqual(restored.options(for: .trash).iconSize, 512)
        XCTAssertEqual(try JSONDecoder().decode(ViewOptions.self, from: Data("{}".utf8)).iconSize, 96)
    }
}
