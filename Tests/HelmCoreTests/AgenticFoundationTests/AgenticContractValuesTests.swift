import XCTest
import HelmCore

/// The plain values other modules build on: what `ai.json` holds, what a disk tells AI mode, and the defaults that
/// keep existing callers as they were.
final class AgenticContractValuesTests: XCTestCase {
    // MARK: AIConfig

    func testAIConfigStartsEmpty() {
        let config = AIConfig()
        XCTAssertNil(config.provider)
        XCTAssertEqual(config.models, [:])
        XCTAssertEqual(config.ports, [:])
        XCTAssertNil(config.otherAddress)
        XCTAssertEqual(config.keyOwners, [:])
        XCTAssertEqual(config.modelLists, [:])
        XCTAssertFalse(config.openAIUsesKey, "OpenAI starts on the ChatGPT sign-in")
    }

    func testAIConfigRoundTrips() throws {
        let config = AIConfig(provider: "claude", models: ["claude": "claude-opus-5-5", "ollama": "llama"],
                              ports: ["ollama": 11434, "lmStudio": 1234], otherAddress: "models.example.com/v1",
                              keyOwners: ["claude|api.anthropic.com:443": "1024-1700000000"],
                              modelLists: ["lmStudio|127.0.0.1:1234": ["qwen-9b", "llama-5-8b"]],
                              openAIUsesKey: true)
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(AIConfig.self, from: data), config)
        XCTAssertEqual(try JSONDecoder().decode(AIConfig.self, from: JSONEncoder().encode(AIConfig())), AIConfig())
    }

    func testAIConfigLoadsOlderAndNewerFiles() throws {
        // An older file with fewer fields, and an empty one.
        let older = try JSONDecoder().decode(AIConfig.self, from: Data(#"{"provider":"ollama"}"#.utf8))
        XCTAssertEqual(older, AIConfig(provider: "ollama"))
        XCTAssertEqual(try JSONDecoder().decode(AIConfig.self, from: Data("{}".utf8)), AIConfig())
        // A newer file with a field this build doesn't know.
        let newer = #"{"provider":"gemini","models":{"gemini":"gemini-4-hydrogen"},"voice":"alto","ports":{}}"#
        XCTAssertEqual(try JSONDecoder().decode(AIConfig.self, from: Data(newer.utf8)),
                       AIConfig(provider: "gemini", models: ["gemini": "gemini-4-hydrogen"]))
        // A field of the wrong shape is a damaged file, not an empty one.
        XCTAssertThrowsError(try JSONDecoder().decode(AIConfig.self, from: Data(#"{"ports":"11434"}"#.utf8)))
    }

    func testAIConfigHasNoPlaceForAKey() throws {
        let config = AIConfig(provider: "claude", models: ["claude": "m"], ports: ["ollama": 11434], otherAddress: "a.example.com",
                              keyOwners: ["claude|api.anthropic.com:443": "stamp"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["provider", "models", "ports", "otherAddress", "keyOwners", "modelLists", "textOnlyModels",
                                          "openAIUsesKey"])
        XCTAssertEqual(object["openAIUsesKey"] as? Bool, false, "a flag, never a key")
        XCTAssertFalse(object.keys.contains { $0.lowercased().contains("secret") || $0.lowercased().contains("token") || $0.lowercased() == "key" })
    }

    // MARK: AgentDisk values

    func testADiskItemsDefaults() {
        let item = AgentDiskItem(path: "/home/helm/Documents/a.txt", name: "a.txt", kind: .regular, identity: nil)
        XCTAssertEqual(item.size, 0)
        XCTAssertEqual(item.modified, .distantPast)
        XCTAssertEqual(item.created, .distantPast)
        XCTAssertNil(item.typeIdentifier)
        XCTAssertFalse(item.isHidden)
        XCTAssertFalse(item.isDataless)
        XCTAssertNil(item.place)
        let identity = FileObjectIdentity(scope: "disk1", object: "42")
        let folder = AgentDiskItem(path: "/home/helm/Documents", name: "Documents", kind: .directory, identity: identity,
                                   isDataless: true, place: StorageFacts(kind: .iCloud, name: "iCloud Drive", syncs: true))
        XCTAssertEqual(folder.identity, identity)
        XCTAssertTrue(folder.isDataless)
        XCTAssertEqual(folder.place?.kind, .iCloud)
        // Items go into sets, place and all.
        XCTAssertEqual(Set([item, folder, item]).count, 2)
    }

    func testADiskListingsDefaults() {
        let listing = AgentDiskListing(items: [])
        XCTAssertEqual(listing.more, 0)
        XCTAssertEqual(listing.unreadable, 0)
        XCTAssertEqual(listing.state, .ok)
        let partial = AgentDiskListing(items: [], more: 12, unreadable: 3, state: .notLoaded)
        XCTAssertEqual([partial.more, partial.unreadable], [12, 3])
        XCTAssertEqual(partial.state, .notLoaded)
        XCTAssertEqual(["ok", "notLoaded", "slow", "denied", "gone"].map { AgentDiskListState(rawValue: $0) },
                       [.ok, .notLoaded, .slow, .denied, .gone])
    }

    /// A disk that holds nothing. The protocol has only ways to look, so a stand-in is four answers.
    private struct EmptyDisk: AgentDisk {
        func canonicalPath(_ path: String) async -> String? { nil }
        func item(at path: String) async -> AgentDiskItem? { nil }
        func list(_ folder: String, limit: Int, idleSeconds: Double) async -> AgentDiskListing { AgentDiskListing(items: [], state: .gone) }
        func storage(of folder: String) async -> StorageFacts { .thisMac }
    }

    func testADiskIsAskedThroughTheProtocol() async {
        let disk: any AgentDisk = EmptyDisk()
        let path = await disk.canonicalPath("/home/helm")
        XCTAssertNil(path)
        let item = await disk.item(at: "/home/helm")
        XCTAssertNil(item)
        let listing = await disk.list("/home/helm", limit: 10, idleSeconds: 3)
        XCTAssertEqual(listing.state, .gone)
        let storage = await disk.storage(of: "/home/helm")
        XCTAssertEqual(storage, .thisMac)
    }

    // MARK: Defaults that keep existing callers as they were

    func testAVolumeIsNotOnAServerUnlessSaid() {
        let url = URL(fileURLWithPath: "/Volumes/Backup", isDirectory: true)
        XCTAssertFalse(VolumeInfo(url: url, name: "Backup").isNetwork)
        XCTAssertFalse(VolumeInfo(url: url, name: "Backup", isInternal: false, isRemovable: true, isCloud: false).isNetwork)
        let share = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/team", isDirectory: true), name: "team", isNetwork: true)
        XCTAssertTrue(share.isNetwork)
        XCTAssertNotEqual(share, VolumeInfo(url: share.url, name: "team"))
        // Being on a server changes nothing about which disks are listed.
        XCTAssertEqual(VolumeFilter.filtered([share]).map(\.name), ["team"])
    }

    func testAHistoryEntryIsOnItsOwnUnlessGivenAGroup() {
        let operation = OperationID()
        XCTAssertNil(HistoryEntry(operationID: operation, name: "Copy").group)
        let group = HistoryGroup(name: "Move 3 Items")
        XCTAssertEqual(HistoryEntry(operationID: operation, name: group.name, group: group).group, group)
        XCTAssertNotEqual(HistoryEntry(operationID: operation, name: "Copy"), HistoryEntry(operationID: operation, name: "Copy", group: group))
    }
}
