import XCTest
import HelmCore
import HelmTestKit
@testable import HelmAgent

/// Whole Mac in a real conversation, with a scripted model: a screenshot in Documents planned into Pictures by the
/// real plan checks, the prompt and note of each scope, a switch mid-thread starting over, every other new thread
/// coming back to This Folder, This Folder as it was, and nothing sent that holds the home folder's path or the
/// person's short name.
final class AgentWholeMacSessionTests: XCTestCase {
    /// The home's last part stands for the person's short name, which must never leave the app.
    private let shortName = "marlowe-quist"
    private var home: String { "/Users/" + shortName }
    private var documents: String { home + "/Documents" }
    private let screenshot = "Screenshot 2026-11-02 at 09.15.00.png"
    private var drive: String { home + "/Library/CloudStorage/GoogleDrive-marlowe@example.com" }
    private let disk0 = "/Volumes/marlowe-quist backup"

    private static let script = """
    {"rules": [
      {"when": "file the screenshot", "turns": [
        {"calls": [{"name": "list_folder", "args": {"folder": "@home", "depth": 2, "after": ""}},
                   {"name": "list_folder", "args": {"folder": "@root", "depth": 1, "after": ""}}]},
        {"text": "The screenshot goes into Screenshots in Pictures.", "calls": [{"name": "propose_changes", "args": {
           "new_folders": [], "new_files": [],
           "moves": [{"items": ["@name:Screenshot 2026-11-02 at 09.15.00.png"], "all_in": "", "to": "@name:Screenshots"}],
           "copies": [], "renames": [], "trash": []}}]}]},
      {"when": "survey", "turns": [
        {"calls": [{"name": "list_folder", "args": {"folder": "@home", "depth": 2, "after": ""}},
                   {"name": "list_folder", "args": {"folder": "r3", "depth": 0, "after": ""}},
                   {"name": "list_folder", "args": {"folder": "r4", "depth": 0, "after": ""}},
                   {"name": "list_folder", "args": {"folder": "r5", "depth": 0, "after": ""}}]},
        {"text": "That's everything."}]},
      {"when": "look", "turns": [
        {"calls": [{"name": "list_folder", "args": {"folder": "@root", "depth": 1, "after": ""}}]},
        {"text": "Looked."}]},
      {"when": "reuse", "turns": [
        {"calls": [{"name": "list_folder", "args": {"folder": "d1", "depth": 1, "after": ""}}]},
        {"text": "Done."}]},
      {"when": "*", "turns": [{"text": "Hello."}]}]}
    """

    private struct Rig {
        let session: AgentSession
        let client: ScriptedModelClient
        let disk: MemoryAgentDisk
    }

    private func rig(validator: any AgentPlanValidating = AgentPlanValidator()) async -> Rig {
        let disk = MemoryAgentDisk(home: home)
        disk.addFolder(documents + "/Archive")
        disk.addFile(documents + "/" + screenshot, size: 800_000, typeIdentifier: "public.png")
        disk.addFile(documents + "/letter.pages")
        disk.addFolder(home + "/Desktop")
        disk.addFolder(home + "/Downloads")
        disk.addFile(home + "/Pictures/Screenshots/older.png")
        disk.addFolder(home + "/Movies")
        disk.addFile(home + "/Library/Preferences/secret.plist")
        disk.addFile(home + "/Library/Mobile Documents/com~apple~CloudDocs/Notes/list.txt")
        disk.addFile(drive + "/My Drive/plan.txt")
        disk.addFile(disk0 + "/Old Photos/beach.jpg")
        disk.setProbe(StorageProbe(isLocal: true, isInternal: false), under: disk0)
        let client = AgentLoopKit.client(Self.script)
        let mounted = disk0
        let parts = AgentSessionParts(client: { .success(client) }, disk: disk, home: home, supportFolder: AgentLoopKit.support,
                                      clock: FakeClock(), mountedVolumes: { [mounted] })
        let session = AgentSession(parts: parts, validator: validator)
        guard case .root(let root) = await session.setTabFolder(AgentRootInput(fromPerson: documents, origin: .tab)) else {
            XCTFail("Documents is the folder on show")
            return Rig(session: session, client: client, disk: disk)
        }
        XCTAssertEqual(root.alias, "r1")
        return Rig(session: session, client: client, disk: disk)
    }

    /// The first notice the conversation gives outside a request, waiting a little for it.
    private func nextNotice(_ session: AgentSession) async -> AgentNotice? {
        await withTaskGroup(of: AgentNotice?.self) { group in
            group.addTask {
                for await notice in session.notices { return notice }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The note Helm put before the person's words in the newest request.
    private func lastNote(_ client: ScriptedModelClient) -> String {
        let texts = (client.sentTurns.last?.history ?? []).compactMap(AgentLoopKit.text(of:))
        return texts.last { $0.hasPrefix("[Helm] Folders:") }?.components(separatedBy: "\n").first ?? ""
    }

    // MARK: A plan across places

    func testAScriptedPlanMovesAScreenshotFromDocumentsToPictures() async throws {
        let rig = await rig()
        await rig.session.setScopeMode(.wholeMac)
        let events = await AgentLoopKit.events(rig.session, "file the screenshot where it belongs")
        let plan = try XCTUnwrap(AgentLoopKit.plans(events).first, "\(AgentLoopKit.words(events))")
        XCTAssertEqual(plan.title, .move(1))
        XCTAssertEqual(plan.steps.count, 1)
        guard case .move(let item, to: .existing(let target)) = plan.steps.first else { return XCTFail("\(plan.steps)") }
        XCTAssertEqual(item.path, documents + "/" + screenshot)
        XCTAssertEqual(item.rootAlias, "r1", "from the folder on show")
        XCTAssertEqual(target.path, home + "/Pictures/Screenshots")
        XCTAssertEqual(target.rootAlias, "r2", "into a folder the home folder's listing gave")
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertNil(plan.groups.first?.guardedBy, "a move on this Mac starts ticked")
        XCTAssertTrue(plan.leftOut.isEmpty)
        XCTAssertEqual(rig.client.sentTurns.first?.system, AgentPrompt.wholeMac)
        XCTAssertEqual(lastNote(rig.client).hasPrefix("[Helm] Folders: r1 this_mac (on show); r2 this_mac home; r3 icloud"), true,
                       lastNote(rig.client))
    }

    // MARK: Switching

    func testSwitchingMidThreadStartsOverWithNothingKept() async {
        let rig = await rig()
        _ = await AgentLoopKit.events(rig.session, "look")
        XCTAssertEqual(rig.client.sentTurns.first?.system, AgentPrompt.system)
        let before = rig.client.sentTurns.count

        await rig.session.setScopeMode(.wholeMac)
        agentEqual(await nextNotice(rig.session), .startedOver)
        agentEqual(await rig.session.scopeMode(), .wholeMac)
        _ = await AgentLoopKit.events(rig.session, "reuse the old folder")
        let first = rig.client.sentTurns[before]
        XCTAssertEqual(first.system, AgentPrompt.wholeMac)
        XCTAssertEqual(first.history.count, 1, "the thread starts with this request alone")
        XCTAssertTrue(lastNote(rig.client).contains(" home"), lastNote(rig.client))
        // An id from the thread before answers as retired, never as the folder it stood for.
        let results = rig.client.sentTurns.last.map { $0.history.flatMap(AgentLoopKit.results(in:)) } ?? []
        XCTAssertEqual(results.map { AgentLoopKit.string($0.json, "code") }, ["stale_id"])

        await rig.session.setScopeMode(.thisFolder)
        agentEqual(await nextNotice(rig.session), .startedOver)
        let count = rig.client.sentTurns.count
        _ = await AgentLoopKit.events(rig.session, "hello")
        XCTAssertEqual(rig.client.sentTurns[count].system, AgentPrompt.system)
        XCTAssertEqual(rig.client.sentTurns[count].history.count, 1)
        XCTAssertFalse(lastNote(rig.client).contains(" home"), lastNote(rig.client))
        let roots = await rig.session.roots()
        XCTAssertEqual(roots.map(\.alias), ["r1"])
    }

    func testSwitchingToTheSameScopeChangesNothing() async {
        let rig = await rig()
        _ = await AgentLoopKit.events(rig.session, "look")
        await rig.session.setScopeMode(.thisFolder)
        _ = await AgentLoopKit.events(rig.session, "hello")
        XCTAssertGreaterThan(rig.client.sentTurns.last?.history.count ?? 0, 1, "the thread goes on")
    }

    func testEveryOtherNewThreadComesBackToThisFolder() async {
        let rig = await rig()
        for start in ["start over", "clear", "remove"] {
            await rig.session.setScopeMode(.wholeMac)
            agentTrue(await rig.session.roots().contains(where: \.isWholeMac), start)
            switch start {
            case "start over": await rig.session.startOver()
            case "clear": await rig.session.clear()
            default:
                rig.disk.addFolder("/Volumes/Spare/Work")
                guard case .added(let added) = await rig.session.folder(for: AgentRootInput(fromPerson: "/Volumes/Spare", origin: .typed)) else {
                    return XCTFail("the disk wasn't added")
                }
                await rig.session.removeRoot(alias: added.alias)
            }
            agentEqual(await rig.session.scopeMode(), .thisFolder, start)
            agentFalse(await rig.session.roots().contains(where: \.isWholeMac), start)
            _ = await AgentLoopKit.events(rig.session, "hello")
            XCTAssertEqual(rig.client.sentTurns.last?.system, AgentPrompt.system, start)
        }
    }

    func testAThreadThatReachesItsLimitInsideARequestStaysInWholeMac() async {
        let rig = await rig()
        await rig.session.setScopeMode(.wholeMac)
        for _ in 0..<AgentLimits.threadRequests { _ = await AgentLoopKit.events(rig.session, "hello") }
        let events = await AgentLoopKit.events(rig.session, "hello")
        XCTAssertTrue(AgentLoopKit.words(events).contains("notice startedOver"), "\(AgentLoopKit.words(events))")
        agentEqual(await rig.session.scopeMode(), .wholeMac)
        XCTAssertEqual(rig.client.sentTurns.last?.system, AgentPrompt.wholeMac, "the request carries on as it was sent")
        XCTAssertEqual(rig.client.sentTurns.last?.history.count, 1)
    }

    // MARK: This Folder as it was

    func testThisFolderIsAsItWas() async {
        let rig = await rig()
        agentEqual(await rig.session.scopeMode(), .thisFolder)
        _ = await AgentLoopKit.events(rig.session, "look")
        XCTAssertEqual(rig.client.sentTurns.first?.system, AgentPrompt.system)
        XCTAssertEqual(lastNote(rig.client), "[Helm] Folders: r1 this_mac (on show).")
        let roots = await rig.session.roots()
        XCTAssertEqual(roots.map(\.alias), ["r1"])
        XCTAssertFalse(rig.disk.asked.contains { AgentPathParts.isAt($0, orInside: self.home + "/Library") },
                       "nothing of Whole Mac is looked at")
        XCTAssertFalse(rig.disk.asked.contains { $0.hasPrefix("/Volumes") })
    }

    // MARK: What leaves the app

    func testWholeMacSendsNoHomePathAndNoShortNameAndTheHomeIsSentAsHome() async throws {
        let rig = await rig(validator: AgentLoopFakeValidator())
        await rig.session.setScopeMode(.wholeMac)
        let roots = await rig.session.roots()
        XCTAssertEqual(roots.map(\.modelName), ["Documents", "Home", "iCloud Drive", "Google Drive", "External disk"])
        let events = await AgentLoopKit.events(rig.session, "survey")
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false }, "\(AgentLoopKit.words(events))")
        let sent = rig.client.allSentText()
        for secret in [home, shortName, "marlowe@example.com", "GoogleDrive", "com~apple~CloudDocs", "Preferences", disk0] {
            XCTAssertFalse(sent.contains(secret), "sent: \(secret)")
        }
        // The home folder's own listing names it Home, and the note marks it.
        let results = rig.client.sentTurns.last.map { $0.history.flatMap(AgentLoopKit.results(in:)) } ?? []
        let homeListing = try XCTUnwrap(results.first { AgentLoopKit.string($0.json, "folder") == "r2" })
        XCTAssertEqual(AgentLoopKit.string(homeListing.json, "name"), "Home")
        XCTAssertEqual(results.compactMap { AgentLoopKit.string($0.json, "name") }, ["Home", "iCloud Drive", "Google Drive", "External disk"])
        XCTAssertTrue(lastNote(rig.client).contains("r2 this_mac home;"), lastNote(rig.client))
        let names = AgentLoopKit.array(homeListing.json, "items").compactMap { AgentLoopKit.string($0, "name") }
        XCTAssertTrue(names.contains("Screenshots"))
        XCTAssertFalse(names.contains("Library"))
        XCTAssertFalse(names.contains("Archive"), "Documents is a leaf of the home folder, never entered")
    }
}
