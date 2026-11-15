import Foundation
import XCTest
import HelmCore
import HelmPersistence

/// ai.json: what AI mode remembers between launches, and that a key is never part of it.
final class AIConfigStoreTests: XCTestCase {
    private let chosen = AIConfig(provider: "ollama", models: ["claude": "claude-opus-5-5", "ollama": "llama"],
                                  ports: ["ollama": 11434], otherAddress: "models.example.com/v1",
                                  keyOwners: ["claude|api.anthropic.com:443": "1024-1700000000"])

    @MainActor func testConfigSurvivesRelaunch() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = StoreLocation(directory: dir).ai
        XCTAssertEqual(url.lastPathComponent, "ai.json")
        XCTAssertEqual(url.deletingLastPathComponent().path, dir.path)
        let store = try await AIConfigStore(url: url)
        XCTAssertEqual(store.config, AIConfig())
        // Nothing is written until something is chosen.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.update { $0 = chosen }
        store.update { $0.models["ollama"] = "llama-next" }
        try await store.flush()
        let reopened = try await AIConfigStore(url: url)
        XCTAssertEqual(reopened.config, store.config)
        XCTAssertEqual(reopened.config.provider, "ollama")
        XCTAssertEqual(reopened.config.models, ["claude": "claude-opus-5-5", "ollama": "llama-next"])
        XCTAssertEqual(reopened.config.ports, ["ollama": 11434])
        XCTAssertEqual(reopened.config.otherAddress, "models.example.com/v1")
        XCTAssertEqual(reopened.config.keyOwners, ["claude|api.anthropic.com:443": "1024-1700000000"])
        // Choosing nothing again is a change like any other, and it survives too.
        reopened.update { $0 = AIConfig() }
        try await reopened.flush()
        let emptied = try await AIConfigStore(url: url)
        XCTAssertEqual(emptied.config, AIConfig())
    }

    @MainActor func testTheFileHasTheShapeOtherBuildsRead() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = StoreLocation(directory: dir).ai
        let store = try await AIConfigStore(url: url)
        store.update { $0 = chosen }
        try await store.flush()
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(document.keys), ["schemaVersion", "items"])
        XCTAssertEqual(document["schemaVersion"] as? Int, 1)
        let items = try XCTUnwrap(document["items"] as? [String: Any])
        XCTAssertEqual(items["provider"] as? String, "ollama")
        XCTAssertEqual(items["models"] as? [String: String], ["claude": "claude-opus-5-5", "ollama": "llama"])
        XCTAssertEqual(items["ports"] as? [String: Int], ["ollama": 11434])
        XCTAssertEqual(items["otherAddress"] as? String, "models.example.com/v1")
        XCTAssertEqual(items["keyOwners"] as? [String: String], ["claude|api.anthropic.com:443": "1024-1700000000"])
    }

    @MainActor func testChangesAreSentOnceAndOnlyForRealChanges() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for store in [AIConfigStore(), try await AIConfigStore(url: StoreLocation(directory: dir).ai)] {
            var sent: [AIConfig] = []
            let token = store.changes.subscribe { sent.append($0) }
            store.update { $0.provider = "claude" }
            store.update { $0.provider = "claude" }
            store.update { _ in }
            store.update { $0.ports["lmStudio"] = 1234 }
            store.update { $0.ports["lmStudio"] = 1234 }
            XCTAssertEqual(sent, [AIConfig(provider: "claude"), AIConfig(provider: "claude", ports: ["lmStudio": 1234])])
            XCTAssertEqual(store.config, AIConfig(provider: "claude", ports: ["lmStudio": 1234]))
            store.changes.cancel(token)
            store.update { $0.provider = nil }
            XCTAssertEqual(sent.count, 2)
            XCTAssertNil(store.config.provider)
            try await store.flush()
        }
    }

    @MainActor func testAStoreWithoutAFileKeepsItsConfigInMemoryOnly() async throws {
        let store = AIConfigStore()
        XCTAssertEqual(store.config, AIConfig())
        store.update { $0 = chosen }
        XCTAssertEqual(store.config, chosen)
        // Saving has nowhere to write, and that is not a failure.
        try await store.flush()
        XCTAssertEqual(AIConfigStore().config, AIConfig())
    }

    @MainActor func testANewerFileIsRefusedRatherThanOverwritten() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = StoreLocation(directory: dir).ai
        let newer = Data(#"{"schemaVersion":2,"items":{"provider":"claude","voice":"alto"}}"#.utf8)
        try newer.write(to: url)
        do {
            _ = try await AIConfigStore(url: url)
            XCTFail("A newer schema loaded")
        } catch { XCTAssertEqual(error as? PersistenceError, .unsupportedVersion(2)) }
        XCTAssertEqual(try Data(contentsOf: url), newer)
    }

    @MainActor func testADamagedFileIsKeptAsideAndNothingIsChosen() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = StoreLocation(directory: dir).ai
        try Data("not json".utf8).write(to: url)
        let store = try await AIConfigStore(url: url)
        XCTAssertEqual(store.config, AIConfig())
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("ai.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
    }

    @MainActor func testTheFileHasNoPlaceForAKey() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = StoreLocation(directory: dir).ai
        // A file that someone gave key fields by hand, beside the fields Helm knows.
        let planted = #"{"schemaVersion":1,"items":{"provider":"claude","key":"planted-value","apiKey":"planted-value","#
            + #""secret":{"claude":"planted-value"},"models":{"claude":"claude-opus-5-5"}}}"#
        try Data(planted.utf8).write(to: url)
        let store = try await AIConfigStore(url: url)
        // The known fields load, and the config has nowhere to hold the rest.
        XCTAssertEqual(store.config, AIConfig(provider: "claude", models: ["claude": "claude-opus-5-5"]))
        XCTAssertEqual(Mirror(reflecting: store.config).children.compactMap(\.label).sorted(),
                       ["keyOwners", "modelLists", "models", "openAIUsesKey", "otherAddress", "ports", "provider"])
        // The next save writes the known fields at most, so what was planted is gone from the file.
        store.update { $0.keyOwners["claude|api.anthropic.com:443"] = "1024-1700000000" }
        try await store.flush()
        let saved = try Data(contentsOf: url)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let items = try XCTUnwrap(document["items"] as? [String: Any])
        XCTAssertTrue(Set(items.keys).isSubset(of: ["provider", "models", "ports", "otherAddress", "keyOwners", "modelLists", "openAIUsesKey"]),
                      "\(items.keys.sorted())")
        XCTAssertFalse(items.keys.contains { name in
            let name = name.lowercased()
            return name == "key" || name.hasSuffix("apikey") || name.contains("secret") || name.contains("token") || name.contains("password")
        })
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("planted-value"))
        // Which build saved a key is kept, by the key's keychain account. That is a name, never the key.
        XCTAssertEqual(items["keyOwners"] as? [String: String], ["claude|api.anthropic.com:443": "1024-1700000000"])
    }
}
