import XCTest
import HelmCore
import HelmPersistence

final class OpenWithStoreTests: XCTestCase {
    @MainActor func testRemembersAppsPerKindNewestFirstAndSurvivesRelaunch() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = StoreLocation(directory: dir).openWith
        XCTAssertEqual(url.lastPathComponent, "open-with.json")
        let store = try await OpenWithStore(url: url)
        store.recordUse(of: "/Applications/A.app", for: "public.png", at: Date(timeIntervalSinceReferenceDate: 1))
        store.recordUse(of: "/Applications/B.app", for: "public.png", at: Date(timeIntervalSinceReferenceDate: 2))
        store.recordUse(of: "/Applications/A.app", for: "public.png", at: Date(timeIntervalSinceReferenceDate: 3))
        store.recordUse(of: "/Applications/C.app", for: "public.plain-text", at: Date(timeIntervalSinceReferenceDate: 4))
        XCTAssertEqual(store.recentApplications(for: "public.png"), ["/Applications/A.app", "/Applications/B.app"])
        try await store.flush()
        let reopened = try await OpenWithStore(url: url)
        XCTAssertEqual(reopened.recentApplications(for: "public.png"), ["/Applications/A.app", "/Applications/B.app"])
        XCTAssertEqual(reopened.recentApplications(for: "public.plain-text"), ["/Applications/C.app"])
    }

    @MainActor func testKeepsOnlyTheNewestFewPerKind() {
        let store = OpenWithStore()
        for index in 0..<10 {
            store.recordUse(of: "/Applications/\(index).app", for: "public.png", at: Date(timeIntervalSinceReferenceDate: Double(index)))
        }
        let recent = store.recentApplications(for: "public.png")
        XCTAssertEqual(recent.count, OpenWithStore.perTypeLimit)
        XCTAssertEqual(recent.first, "/Applications/9.app")
    }
}
