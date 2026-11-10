import XCTest
import HelmCore
import HelmPersistence

final class MigrationTests: XCTestCase {
    @MainActor func testBothDomainsUnionNewestDatesAndSettingsPrecedence() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let memory = MemoryDefaults()
        memory.values["com.helm.starredFiles"] = Data(#"["file:///Users/test/a"]"#.utf8)
        memory.values["helm.bookmarks"] = Data(#"["file:///Volumes/offline/Folder"]"#.utf8)
        memory.values["helm.recentAccessRecords"] = Data(#"[{"path":"/Users/test/a","lastAccessedAt":1}]"#.utf8)
        memory.domains["Helm"] = [
            "com.helm.starredFiles": Data(#"["file:///Users/test/a","file:///Users/test/b"]"#.utf8),
            "helm.bookmarks": Data(#"["file:///Users/test","file:///Volumes/offline/Folder"]"#.utf8),
            "helm.recentAccessRecords": Data(#"[{"path":"/Users/test/a","lastAccessedAt":5},{"path":"/offline","lastAccessedAt":3}]"#.utf8),
            "helm.gridIconSize": SettingValue.double(64),
            "helm.confirmBeforeTrash": SettingValue.bool(true),
            "helm.showHiddenFiles": SettingValue.bool(true)
        ]
        memory.domains["com.helm.filemanager"] = [
            "helm.gridIconSize": SettingValue.double(112),
            "helm.showHiddenFiles": "invalid explicit value",
            "com.helm.starredFiles": Data(#"["file:///Users/test/c"]"#.utf8)
        ]
        let original = memory.values["helm.bookmarks"] as? Data
        let migrator = LegacyDefaultsMigrator(reader: memory, destination: memory, directory: dir,
                                             home: URL(fileURLWithPath: "/Users/test"))
        let migrated = try await migrator.migrate(at: Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertTrue(migrated)
        let stars = try await StarStore(url: dir.appendingPathComponent("stars.json"))
        XCTAssertEqual(stars.records.map(\.path), ["/Users/test/a", "/Users/test/b", "/Users/test/c"])
        XCTAssertEqual(stars.records.first?.addedAt, Date(timeIntervalSinceReferenceDate: 100))
        let bookmarks = try await BookmarkStore(url: dir.appendingPathComponent("bookmarks.json"),
                                                home: URL(fileURLWithPath: "/Users/test"))
        XCTAssertEqual(Set(bookmarks.records.map(\.name)), Set(["Home", "Folder"]))
        let recent = try await RecentStore(url: dir.appendingPathComponent("recent.json"))
        XCTAssertEqual(recent.records.map(\.path), ["/Users/test/a", "/offline"])
        XCTAssertEqual(recent.records.first?.lastAccessedAt, Date(timeIntervalSinceReferenceDate: 5))
        XCTAssertEqual(memory.values["helm.gridIconSize"] as? Double, 112)
        XCTAssertEqual(memory.values["helm.confirmBeforeTrash"] as? Bool, true)
        XCTAssertNil(memory.values["helm.showHiddenFiles"]) // invalid explicit bundle value is not replaced from Helm
        XCTAssertEqual(memory.values["helm.bookmarks"] as? Data, original)
        XCTAssertEqual(memory.values[LegacyDefaultsMigrator.doneKey] as? Bool, true)
        let repeated = try await migrator.migrate()
        XCTAssertFalse(repeated)
    }
    /// One damaged key costs only itself: the others migrate, it stays untouched, and it's retried (FB2-9).
    @MainActor func testMalformedKeyReportsOnceAndOtherKeysStillMigrate() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let memory = MemoryDefaults()
        memory.values["com.helm.starredFiles"] = Data(#"["file:///safe"]"#.utf8)
        memory.domains["Helm"] = ["helm.bookmarks": Data("invalid".utf8)]
        var reports: [String] = []
        let migrator = LegacyDefaultsMigrator(reader: memory, destination: memory, directory: dir,
                                             home: URL(fileURLWithPath: "/home"), report: { reports.append($0) })
        for _ in 0..<2 {
            do { try await migrator.migrate(); XCTFail("malformed source accepted") } catch {}
        }
        XCTAssertEqual(reports.count, 1)
        XCTAssertNil(memory.values[LegacyDefaultsMigrator.doneKey])
        let stars = try Data(contentsOf: dir.appendingPathComponent("stars.json"))
        XCTAssertTrue(String(decoding: stars, as: UTF8.self).contains("safe"))
        XCTAssertEqual(memory.domains["Helm"]?["helm.bookmarks"] as? Data, Data("invalid".utf8))
    }
    @MainActor func testRetryMergesAlreadyWrittenDataAndPreservesDates() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Simulate interruption after an earlier atomic stars write, before the done flag.
        let originalDate = Date(timeIntervalSinceReferenceDate: 8)
        let old = VersionedDocument(items: [StarRecord(path: "/existing", addedAt: originalDate)])
        try JSONEncoder().encode(old).write(to: dir.appendingPathComponent("stars.json"))
        let memory = MemoryDefaults()
        memory.values["com.helm.starredFiles"] = Data(#"["file:///existing","file:///new"]"#.utf8)
        let migrator = LegacyDefaultsMigrator(reader: memory, destination: memory, directory: dir,
                                             home: URL(fileURLWithPath: "/home"))
        try await migrator.migrate(at: Date(timeIntervalSinceReferenceDate: 20))
        let stars = try await StarStore(url: dir.appendingPathComponent("stars.json"))
        XCTAssertEqual(stars.records.count, 2)
        XCTAssertEqual(stars.records.first(where: { $0.path == "/existing" })?.addedAt, originalDate)
    }
    @MainActor func testExistingFutureFileBlocksMigrationWithoutFlagOrWrites() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(#"{"schemaVersion":2,"items":[]}"#.utf8)
        let url = dir.appendingPathComponent("bookmarks.json")
        try bytes.write(to: url)
        let memory = MemoryDefaults()
        memory.values["com.helm.starredFiles"] = Data(#"["file:///new"]"#.utf8)
        let migrator = LegacyDefaultsMigrator(reader: memory, destination: memory, directory: dir,
                                             home: URL(fileURLWithPath: "/home"))
        do { try await migrator.migrate(); XCTFail("future schema accepted") }
        catch { XCTAssertEqual(error as? PersistenceError, .unsupportedVersion(2)) }
        XCTAssertNil(memory.values[LegacyDefaultsMigrator.doneKey])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("stars.json").path))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
