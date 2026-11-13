import XCTest
import HelmCore
import HelmTestKit
@testable import HelmAgent

/// What leaves the app, over whole scripted requests, with a home folder whose last part is a marker word: no home
/// path, no marker, no account from a cloud folder's name and no server host; names only inside tool results; one
/// system prompt; and a tool result that would carry the home path is never sent.
final class AgentOutboundTests: XCTestCase {
    private let marker = "zebramarker"
    private var home: String { "/private/tmp/agentic-outbound/" + marker }
    private var provider: String { home + "/Library/CloudStorage/GoogleDrive-me@example.com" }
    private let server = "/Volumes/standinhost"
    private let fileNames = ["report.pdf", "photo.png", "Projects", "plan.txt", "My Drive", "Team", "notes.txt", "Budget.xlsx"]

    private static let script = """
    {"rules": [
      {"when": "survey", "turns": [
        {"calls": [{"name": "list_folder", "args": {"folder": "@root", "depth": 0, "after": ""}},
                   {"name": "list_folder", "args": {"folder": "r2", "depth": 0, "after": ""}},
                   {"name": "list_folder", "args": {"folder": "r3", "depth": 0, "after": ""}}]},
        {"calls": [{"name": "find_items", "args": {"folder": "@root", "name_any": ["report"], "kinds": [], "modified_from": "",
                    "modified_to": "", "min_bytes": 0, "max_bytes": 0}}]},
        {"text": "Photos go into Projects.", "calls": [{"name": "propose_changes", "args": {"new_folders": [],
           "moves": [{"items": ["@name:photo.png"], "all_in": "", "to": "@name:Projects"}], "copies": [], "renames": [], "trash": []}}]}]},
      {"when": "*", "turns": [{"text": "Hello."}]}]}
    """

    private struct Rig {
        let session: AgentSession
        let client: ScriptedModelClient
        let disk: MemoryAgentDisk
    }

    private func rig() async -> Rig {
        let disk = MemoryAgentDisk(home: home)
        disk.addFile(home + "/Projects/report.pdf", size: 410_000)
        disk.addFile(home + "/photo.png", size: 2_000_000)
        disk.addFile(provider + "/My Drive/plan.txt")
        disk.addFile(provider + "/My Drive/Budget.xlsx")
        disk.markCloudOnly(provider + "/My Drive/Budget.xlsx")
        disk.addFile(server + "/Team/notes.txt")
        disk.setProbe(StorageProbe(isLocal: false), under: server)
        let client = AgentLoopKit.client(Self.script)
        let session = AgentSession(parts: AgentLoopKit.parts(client, disk: disk, home: home), validator: AgentLoopFakeValidator())
        let tab = await session.setTabFolder(AgentRootInput(fromPerson: home, origin: .tab))
        let cloud = await session.folder(for: AgentRootInput(fromPerson: provider, origin: .typed))
        let share = await session.folder(for: AgentRootInput(fromPerson: "file://" + server, origin: .dropped))
        XCTAssertEqual([tab, cloud, share].map(Self.alias), ["r1", "r2", "r3"])
        return Rig(session: session, client: client, disk: disk)
    }

    private static func alias(_ answer: Any) -> String? {
        switch answer {
        case let tab as AgentTabFolder: if case .root(let root) = tab { return root.alias }
        case let ref as AgentFolderRef: return ref.modelID
        default: break
        }
        return nil
    }

    private func runAll(_ rig: Rig) async -> [[String]] {
        var all: [[String]] = []
        all.append(AgentLoopKit.words(await AgentLoopKit.events(rig.session, "survey my folders", selected: [home + "/photo.png"])))
        all.append(AgentLoopKit.words(await AgentLoopKit.events(rig.session, "hello")))
        return all
    }

    func testNothingSentHoldsTheHomePathTheMarkerAnAccountOrAServerHost() async {
        let rig = await self.rig()
        let words = await runAll(rig)
        XCTAssertTrue(words[0].contains("plan"), "\(words[0])")
        let sent = rig.client.allSentText()
        XCTAssertFalse(sent.isEmpty)
        for secret in [home, marker, "me@example.com", "GoogleDrive-me", "standinhost", "/private/tmp", "/Volumes", "/Library"] {
            XCTAssertFalse(sent.contains(secret), "\(secret) left the app")
        }
        // What was sent is what the model needed: the files, by name, in tool results.
        for name in ["report.pdf", "photo.png", "plan.txt", "notes.txt", "Budget.xlsx"] {
            XCTAssertTrue(sent.contains(name), name)
        }
    }

    func testRootsAreNamedHomeTheProviderAndServer() async {
        let rig = await self.rig()
        _ = await runAll(rig)
        let listings = rig.client.sentTurns.flatMap { turn in turn.history.flatMap(AgentLoopKit.results(in:)) }
            .map(\.json).filter { AgentLoopKit.string($0, "source") == "folder_listing" }
        let names = Dictionary(listings.map { (AgentLoopKit.string($0, "folder") ?? "", AgentLoopKit.string($0, "name") ?? "") },
                               uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(names, ["r1": "Home", "r2": "Google Drive", "r3": "Server"])
        let places = Dictionary(listings.map { (AgentLoopKit.string($0, "folder") ?? "", AgentLoopKit.string($0, "place") ?? "") },
                                uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(places, ["r1": "this_mac", "r2": "cloud", "r3": "server"])
        let note = rig.client.sentTurns.first.flatMap { AgentLoopKit.text(of: $0.history[0]) } ?? ""
        XCTAssertEqual(note, #"[Helm] Folders: r1 this_mac (on show); r2 cloud "Google Drive" syncs shared=unknown; r3 server shared no_trash. 1 item is selected in r1."# + "\nsurvey my folders")
        let later = rig.client.sentTurns.last.flatMap { AgentLoopKit.text(of: $0.history.last!) } ?? ""
        XCTAssertTrue(later.hasPrefix(#"[Helm] Folders: r1 this_mac (on show); r2 cloud "Google Drive" syncs shared=unknown some_not_downloaded; r3"#), later)
    }

    func testNamesAppearOnlyInToolResults() async {
        let rig = await self.rig()
        _ = await runAll(rig)
        for turn in rig.client.sentTurns {
            for item in turn.history {
                guard case .object(var members) = item else { continue }
                members["results"] = nil
                let outside = String(decoding: AgentJSON.object(members).data(), as: UTF8.self)
                for name in fileNames where !["Projects"].contains(name) {
                    XCTAssertFalse(outside.contains(name), "\(name) outside a tool result: \(outside)")
                }
            }
        }
        // The model's own reply named a folder; that is the model's text, and Helm never wrote a name there itself.
        let ownText = rig.client.sentTurns.last!.history.filter { AgentLoopKit.string($0, "role") == "user" }
            .compactMap(AgentLoopKit.text(of:))
        XCTAssertEqual(ownText.count, 2)
        for text in ownText { XCTAssertFalse(fileNames.contains { text.contains($0) }, text) }
    }

    func testTheSystemPromptIsByteIdenticalAcrossTurns() async {
        let rig = await self.rig()
        _ = await runAll(rig)
        XCTAssertGreaterThan(rig.client.sentTurns.count, 3)
        for turn in rig.client.sentTurns {
            XCTAssertEqual(Data(turn.system.utf8), Data(AgentPrompt.system.utf8))
            XCTAssertEqual(turn.tools, AgentToolCatalog.all)
        }
        XCTAssertFalse(AgentPrompt.system.contains("\n"))
        XCTAssertLessThan(AgentPrompt.system.split(separator: " ").count, 200)
    }

    func testAToolResultMadeToHoldTheHomePathEndsTheRequestAndIsNotSent() async {
        for spelling in [home, home.replacingOccurrences(of: "/", with: "\\/")] {
            let rig = await self.rig()
            await rig.session.setToolResultHookForTesting { json in json.replacingOccurrences(of: "Home", with: spelling) }
            let words = AgentLoopKit.words(await AgentLoopKit.events(rig.session, "survey"))
            XCTAssertEqual(words.suffix(2), ["failed unreadable", "finished"], spelling)
            XCTAssertEqual(rig.client.sentTurns.count, 1, spelling)
            _ = await AgentLoopKit.events(rig.session, "hello")
            let sent = rig.client.allSentText()
            XCTAssertFalse(sent.contains(home), spelling)
            XCTAssertFalse(sent.contains(marker), spelling)
            XCTAssertFalse(rig.client.sentTurns.last!.history.contains { AgentLoopKit.member($0, "calls") != nil },
                           "the turn whose result failed the check is not in the thread")
        }
    }

    func testTheCheckItself() {
        XCTAssertTrue(AgentOutboundCheck.helmTextIsClean(#"{"name":"Home"}"#, home: home))
        XCTAssertFalse(AgentOutboundCheck.helmTextIsClean("x" + home + "/a", home: home))
        XCTAssertFalse(AgentOutboundCheck.helmTextIsClean(home.replacingOccurrences(of: "/", with: "\\/"), home: home + "/"))
        XCTAssertTrue(AgentOutboundCheck.helmTextIsClean("anything", home: "/"))
        XCTAssertTrue(AgentOutboundCheck.helmTextIsClean(marker, home: home), "the last part alone is a name, not the path")
    }
}
