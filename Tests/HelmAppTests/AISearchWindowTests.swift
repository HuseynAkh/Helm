#if os(macOS)
import AppKit
import XCTest
import HelmAgent
import HelmCore
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmApp
@testable import HelmUI

/// Searching with a model's help in a real window on an in-memory home: the spark, Return, the plain results first
/// and the ranked order after, reasons as tooltips, the status bar's line and its queries, what is never sent, and
/// how a failure, Escape, a late answer, a server and "Find with AI" behave. Spotlight is stood in for by
/// `HostEffectRunner.spotlightAnswersForTesting` (the plain search) and `AISearchRunner.fanOutAnswersForTesting`
/// (the planned queries); the model is a stand-in that answers from fixed JSON.
@MainActor final class AISearchWindowTests: XCTestCase {
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []
    private let home = URL(fileURLWithPath: "/home/aisearch", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var spotlight = AISearchWindowSpotlight()

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        spotlight = AISearchWindowSpotlight()
        let stand = spotlight
        HostEffectRunner.spotlightAnswersForTesting = { _ in stand.stream() }
    }
    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers = []; keep = []; fileSystems = []
        HostEffectRunner.spotlightAnswersForTesting = nil
        AISearchRunner.fanOutAnswersForTesting = nil
        HeaderMotion.isDisabledForTesting = false
        super.tearDown()
    }

    // MARK: The window

    private let reports = (1...6).map { "report-\($0).txt" }
    private var scan: URL { documents.appendingPathComponent("Scan_0042.pdf") }
    /// What the planned queries find besides the scan: a file in a dot folder, a key file, a file with the hidden
    /// flag, a file in a folder with the hidden flag, and one outside the home folder. None may be a result or a row.
    private var forbidden: [URL] {
        [documents.appendingPathComponent(".secret/scan-dot.txt"), documents.appendingPathComponent("scan.pem"),
         documents.appendingPathComponent("flagged-scan.txt"), documents.appendingPathComponent("Vault/scan-vault-secret.txt"),
         URL(fileURLWithPath: "/elsewhere/outside-scan.txt")]
    }
    private var fileSystems: [AISearchWindowFileSystem] = []

    private func window(client: AISearchWindowClient, on: Bool = true,
                        storage: MemoryStorageFactsReader? = nil) async throws -> (BrowserWindowController, InMemoryFileSystem) {
        let env = try await AppEnvironment.test(home: home)
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        for folder in [documents, documents.appendingPathComponent(".secret"), documents.appendingPathComponent("Vault"),
                       URL(fileURLWithPath: "/elsewhere")] {
            try await memory.createDirectory(at: folder)
        }
        for name in reports + ["Scan_0042.pdf", "scan.pem", "flagged-scan.txt", ".secret/scan-dot.txt", "Vault/scan-vault-secret.txt"] {
            try await memory.createFileExclusively(at: documents.appendingPathComponent(name), contents: Data(name.utf8))
        }
        try await memory.createFileExclusively(at: URL(fileURLWithPath: "/elsewhere/outside-scan.txt"), contents: Data([1]))
        let fileSystem = AISearchWindowFileSystem(base: memory, flagged: [documents.appendingPathComponent("flagged-scan.txt").path,
                                                                          documents.appendingPathComponent("Vault").path])
        fileSystems.append(fileSystem)
        let operations = OperationCoordinator(fileSystem: fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        let secrets = MemorySecretStore()
        let parts = AgentRuntimeParts(secrets: secrets, disk: MemoryAgentDisk(home: home.path), home: home.path,
                                      supportFolder: home.appendingPathComponent(".support").path, clock: env.clock,
                                      buildStamp: "", scripted: client)
        let runtime = AgentRuntime(parts: parts)
        runtime.setOn(on)
        let agent = AgentServices(runtime: runtime, config: AIConfigStore(), secrets: secrets, disk: MemoryAgentDisk(home: home.path),
                                  storage: storage ?? MemoryStorageFactsReader(home: home), connector: MemoryServerConnector())
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: fileSystem,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.ai-search.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith, agent: agent)
        let host = AISearchWindowHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "ai-search", seeds: [], activeIndex: 0)
        keep += [host, operations, volumes, runtime]
        controllers.append(controller)
        controller.navigate(to: .directory(documents))
        let arrived = await until { controller.activeTab?.location == .directory(self.documents) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "Documents never opened")
        return (controller, memory)
    }

    /// The fan-out's stand-in: every planned query finds the scan and the items that must never be rows.
    private func standInFanOut() {
        let found = [scan] + forbidden + reports.map { documents.appendingPathComponent($0) }
        AISearchRunner.fanOutAnswersForTesting = { _ in found }
    }

    private func until(_ timeout: TimeInterval = 30, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
    private func settle(_ seconds: Double = 0.4) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private func names(_ controller: BrowserWindowController) -> [String] {
        guard let tab = controller.activeTab else { return [] }
        return tab.snapshot.sortedEntries.prefix(tab.snapshot.rootCount).map(\.name)
    }

    /// Types the words with the spark on, waits for the plain search, then presses Return.
    private func searchWithAI(_ controller: BrowserWindowController, _ text: String) async {
        controller.setAISearchForTesting(true)
        controller.typeIntoSearchForTesting(text)
        _ = await until { controller.activeTab?.search?.query.text == text && controller.activeTab?.search?.isGathering == false }
        controller.submitSearchForTesting()
    }

    private func plan(_ queries: String, sort: String = "relevance") -> String {
        "{\"sort\": \"\(sort)\", \"queries\": [\(queries)]}"
    }

    // MARK: Return, baseline, ranking

    func testReturnShowsThePlainResultsFirstThenTheRankedOrderAndALatePlainResultChangesNothing() async throws {
        standInFanOut()
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\"scan\"]}"),
                                          rank: "{\"ranked\": [{\"row\": 3, \"why\": [\"name\"]}, {\"row\": 1, \"why\": [\"name\"]}]}")
        client.close("search_plan"); client.close("search_rank")
        let (controller, memory) = try await window(client: client)
        XCTAssertFalse(controller.isAISearchOnForTesting, "off at launch")

        await searchWithAI(controller, "report")
        let thinking = await until { controller.activeTab?.search?.assist?.phase == .thinking }
        XCTAssertTrue(thinking)
        XCTAssertEqual(controller.activeTab?.search?.query.usesAI, true)
        let plain = await until { Set(self.names(controller)) == Set(self.reports) }
        XCTAssertTrue(plain, "the plain results show while the model thinks: \(names(controller))")
        XCTAssertEqual(controller.activeTab?.search?.assist?.phase, .thinking)
        XCTAssertEqual(controller.aiSearchStatusForTesting?.text, AgentText.searchThinking)
        XCTAssertNil(controller.contentStateForTesting, "no page in place of the results while the model thinks")

        // The plan comes: the merged list shows at once, the planned query's find first.
        client.open("search_plan")
        let merged = await until { self.names(controller).first == "Scan_0042.pdf" }
        XCTAssertTrue(merged, "the merged list: \(names(controller))")
        let fused = names(controller)
        XCTAssertEqual(Set(fused), Set(reports + ["Scan_0042.pdf"]), "nothing that may not be a result")
        XCTAssertEqual(controller.activeTab?.search?.assist?.phase, .thinking, "the second question is still out")

        // The ranking comes: its rows first, the rest after in the merged order.
        client.open("search_rank")
        let done = await until { controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(done)
        let ranked = [fused[2], fused[0]] + fused.enumerated().filter { $0.offset != 0 && $0.offset != 2 }.map(\.element)
        XCTAssertEqual(names(controller), ranked)

        // A later plain result arrives, for a file made since. It doesn't put the plain order back.
        try await memory.createFileExclusively(at: documents.appendingPathComponent("report-late.txt"), contents: Data([1]))
        spotlight.yield([documents.appendingPathComponent("report-late.txt"), documents.appendingPathComponent("report-1.txt")])
        await settle(0.8)
        XCTAssertEqual(names(controller), ranked, "the runner is the only sender once its list is on show")
        XCTAssertGreaterThanOrEqual(spotlight.yields, 1)
    }

    func testTheReasonIsTheRowsTooltipInTheListAndTheGrid() async throws {
        standInFanOut()
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\"scan\"], \"kinds\": [\"pdf\"]}"),
                                          rank: "{\"ranked\": [{\"row\": 1, \"why\": [\"name\", \"kind\", \"size\"]}]}")
        let (controller, _) = try await window(client: client)
        controller.perform(.list)
        await searchWithAI(controller, "report")
        let done = await until { controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(done)
        let listed = await until { controller.matchReasonForTesting(named: "Scan_0042.pdf") != nil }
        XCTAssertTrue(listed)
        XCTAssertEqual(controller.matchReasonForTesting(named: "Scan_0042.pdf"), "Name has “scan” · PDF", "two facts at most")
        XCTAssertNil(controller.matchReasonForTesting(named: "report-1.txt"), "a plain match has no reason")
        controller.perform(.grid)
        let grid = await until { controller.activeTab?.viewMode == .grid }
        XCTAssertTrue(grid)
        await settle(0.2)
        XCTAssertEqual(controller.matchReasonForTesting(named: "Scan_0042.pdf"), "Name has “scan” · PDF")
        controller.perform(.list)
        await settle(0.2)
        XCTAssertEqual(controller.matchReasonForTesting(named: "Scan_0042.pdf"), "Name has “scan” · PDF", "and back in the list")
    }

    func testTheStatusBarReadsTheRequestAndHoldsEveryQueryThatRan() async throws {
        standInFanOut()
        let client = AISearchWindowClient(plan: plan("""
            {"name_any": ["scan"], "kinds": ["pdf"]}, {"name_any": ["scan", "invoice"]}, {"content_all": ["report"]}
            """), rank: "{\"ranked\": []}")
        let (controller, _) = try await window(client: client)
        controller.setAISearchForTesting(true)
        XCTAssertEqual(controller.aiSearchStatusForTesting?.text, AgentText.searchHint("Claude"), "the hint before Return")
        await searchWithAI(controller, "report")
        let done = await until { controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(done)
        let status = try XCTUnwrap(controller.aiSearchStatusForTesting)
        XCTAssertEqual(status.queries, ["PDF · “scan”", "“scan”", "Mentions “report”"],
                       "“invoice” was neither typed nor in a result's name")
        XCTAssertTrue(status.text.hasPrefix("\(names(controller).count) matches · PDF · “scan”"), status.text)
    }

    func testAWordAModelChoseAloneIsNeverInTheStatusBarOrItsQueries() async throws {
        standInFanOut()
        let chosen = ["Helm", "license", "expired", "visit", "helm-renew.example", "now"]
        let words = chosen.map { "\"\($0)\"" }.joined(separator: ", ")
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\(words)]}, {\"name_any\": [\"scan\", \(words)]}"),
                                          rank: "{\"ranked\": []}")
        let (controller, _) = try await window(client: client)
        await searchWithAI(controller, "report")
        let done = await until { controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(done)
        let status = try XCTUnwrap(controller.aiSearchStatusForTesting)
        for shown in [status.text] + status.queries {
            for word in chosen {
                XCTAssertFalse(shown.contains("“\(word)”"), "“\(word)” in “\(shown)”")
            }
            XCTAssertFalse(shown.contains("helm-renew.example"), shown)
        }
        XCTAssertEqual(status.queries, ["“scan”"], "a result bears “scan”; the first query has nothing left to show")
        XCTAssertEqual(status.text, "\(names(controller).count) matches")
    }

    // MARK: What is never sent

    func testRowsThatMayNotBeSentNeverAreAlsoWithShowHiddenFilesOn() async throws {
        standInFanOut()
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\"scan\"]}, {\"name_any\": [\"report\"]}"),
                                          rank: "{\"ranked\": [{\"row\": 1, \"why\": [\"name\"]}]}")
        let (controller, _) = try await window(client: client)
        controller.perform(.hidden)
        let hidden = await until { controller.activeTab?.showHidden == true }
        XCTAssertTrue(hidden, "Show Hidden Files is on")
        for everywhere in [false, true] {
            client.reset()
            controller.setAISearchForTesting(true)
            controller.setSearchScopeForTesting(everywhere: everywhere)
            await searchWithAI(controller, "scan report")
            let done = await until { controller.activeTab?.search?.assist?.phase == .done }
            XCTAssertTrue(done)
            let sent = client.allSentText()
            XCTAssertEqual(client.asks.map(\.schemaName), ["search_plan", "search_rank"], "both questions were asked")
            XCTAssertTrue(sent.contains("Scan_0042.pdf"), "the allowed rows were sent")
            for url in forbidden {
                XCTAssertFalse(sent.contains(url.lastPathComponent), "\(url.lastPathComponent) was sent")
                XCTAssertFalse(names(controller).contains(url.lastPathComponent), "\(url.lastPathComponent) is a result")
            }
            XCTAssertFalse(sent.contains(home.path), "no home path is sent")
            XCTAssertFalse(sent.contains("aisearch"), "the account's name isn't sent")
            XCTAssertFalse(sent.contains(".secret"))
            XCTAssertFalse(sent.contains("Vault"), "a folder with the hidden flag isn't named either")
        }
    }

    func testEveryLookupOfAnAISearchRunsWithDownloadsOff() async throws {
        standInFanOut()
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\"scan\"]}, {\"name_any\": [\"report\"]}"),
                                          rank: "{\"ranked\": []}")
        let (controller, _) = try await window(client: client)
        let fileSystem = try XCTUnwrap(fileSystems.last)
        controller.setAISearchForTesting(true)
        controller.typeIntoSearchForTesting("report")
        _ = await until { controller.activeTab?.search?.query.text == "report" && controller.activeTab?.search?.isGathering == false }
        fileSystem.lookups.removeAll()
        controller.submitSearchForTesting()
        let done = await until { controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(done)
        let lookups = fileSystem.lookups.all
        let found = Set(([scan] + forbidden + reports.map { documents.appendingPathComponent($0) }).map(\.path))
        XCTAssertTrue(lookups.contains { found.contains($0.path) }, "the planned queries' hits were looked up")
        XCTAssertTrue(lookups.contains { $0.path == documents.appendingPathComponent("Vault").path }, "and the folders above them")
        XCTAssertTrue(lookups.contains { $0.path == documents.path && $0.downloadsOff }, "the folder above the reports too")
        // The plain search on the person's words looks at the folder it walks as it always has; nothing else is
        // looked up with downloads on.
        let on = lookups.filter { !$0.downloadsOff && $0.path != documents.path }
        XCTAssertEqual(on.map(\.path), [], "every lookup of the AI search ran with downloads off")
    }

    func testNothingIsSentWhileTyping() async throws {
        standInFanOut()
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\"scan\"]}"), rank: "{\"ranked\": []}")
        let (controller, _) = try await window(client: client)
        controller.setAISearchForTesting(true)
        for text in ["s", "sc", "scan", "scan pdf"] {
            controller.typeIntoSearchForTesting(text)
            await settle(0.1)
        }
        let typed = await until { controller.activeTab?.search?.query.text == "scan pdf" && controller.activeTab?.search?.isGathering == false }
        XCTAssertTrue(typed)
        await settle(0.6)
        XCTAssertTrue(client.asks.isEmpty, "typing searches names only")
        XCTAssertEqual(controller.activeTab?.search?.query.usesAI, false)
        controller.submitSearchForTesting()
        let asked = await until { !client.asks.isEmpty }
        XCTAssertTrue(asked, "Return sends")
        XCTAssertTrue(client.asks.first?.user.contains("scan pdf") == true)
    }

    func testWordsThatHoldAKeyAreNeverSent() async throws {
        standInFanOut()
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\"report\"]}"), rank: "{\"ranked\": []}")
        let (controller, _) = try await window(client: client)
        let key = "sk-ant-api03-testfake0123456789abcdefghij"
        await searchWithAI(controller, "report \(key)")
        let said = await until { controller.aiSearchStatusForTesting?.text == AgentText.composerLooksLikeKey }
        XCTAssertTrue(said, "the status bar says why nothing was asked")
        await settle(0.6)
        XCTAssertTrue(client.asks.isEmpty, "no question went to the model")
        XCTAssertFalse(client.allSentText().contains(key))
        controller.submitSearchForTesting()
        await settle(0.6)
        XCTAssertTrue(client.asks.isEmpty, "Return again sends nothing either")
    }

    // MARK: Failures and cancelling

    func testAModelFailureKeepsTheNameMatchesAndSaysSo() async throws {
        standInFanOut()
        let client = AISearchWindowClient(plan: nil, rank: nil)
        let (controller, _) = try await window(client: client)
        await searchWithAI(controller, "report")
        let failed = await until { controller.activeTab?.search?.assist?.phase == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(controller.aiSearchStatusForTesting?.text, AgentText.failUnreadable, "the status bar says why")
        XCTAssertEqual(controller.aiSearchStatusForTesting?.queries, [])
        XCTAssertEqual(Set(names(controller)), Set(reports), "the name matches stay")
        XCTAssertTrue(controller.isAISearchOnForTesting, "Return again tries again")
    }

    func testEscapeCancelsTheModelCall() async throws {
        standInFanOut()
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\"scan\"]}"), rank: "{\"ranked\": []}")
        client.close("search_plan")
        let (controller, _) = try await window(client: client)
        await searchWithAI(controller, "report")
        let asked = await until { client.asks.count == 1 }
        XCTAssertTrue(asked)
        if !controller.searchFieldKeyForTesting("escape") { controller.headerSearchClosed() }
        let cancelled = await until(10) { client.cancelled > 0 }
        XCTAssertTrue(cancelled, "the question was cancelled")
        XCTAssertNil(controller.activeTab?.search)
        XCTAssertFalse(controller.isAISearchOnForTesting, "the spark goes off when the search closes")
        client.open("search_plan")
        await settle()
        XCTAssertEqual(client.asks.count, 1, "nothing more was asked")
    }

    func testALateAnswerIsDropped() async throws {
        standInFanOut()
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\"scan\"]}"), rank: "{\"ranked\": []}")
        client.close("search_plan")
        client.ignoresCancel = true
        let (controller, _) = try await window(client: client)
        await searchWithAI(controller, "report")
        let asked = await until { client.asks.count == 1 }
        XCTAssertTrue(asked)
        // New words: a plain search, which also cancels the AI one.
        controller.typeIntoSearchForTesting("report-1")
        let plain = await until { controller.activeTab?.search?.query.text == "report-1" && controller.activeTab?.search?.isGathering == false }
        XCTAssertTrue(plain)
        // The model answers anyway, too late.
        client.open("search_plan")
        await settle(1.0)
        XCTAssertEqual(controller.activeTab?.search?.query.usesAI, false)
        XCTAssertNil(controller.activeTab?.search?.assist, "the late answer added nothing")
        XCTAssertEqual(names(controller), ["report-1.txt"])
        XCTAssertEqual(controller.aiSearchStatusForTesting?.text, AgentText.searchHint("Claude"), "only the hint: nothing ran")
    }

    // MARK: Places, the spark and Find with AI

    func testAServerReadsNamesOnly() async throws {
        standInFanOut()
        let storage = MemoryStorageFactsReader(home: home)
        storage.set(StorageProbe(isLocal: false), under: documents.path)
        let client = AISearchWindowClient(plan: plan("{\"content_all\": [\"plumber\"]}"), rank: "{\"ranked\": []}")
        let (controller, _) = try await window(client: client, storage: storage)
        await searchWithAI(controller, "plumber report")
        let done = await until { controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(done)
        let status = try XCTUnwrap(controller.aiSearchStatusForTesting)
        // One part of the dot list, so without the sentence's full stop.
        XCTAssertTrue(status.text.hasSuffix(" · " + AgentText.searchNamesOnly.dropLast()), status.text)
        XCTAssertFalse(status.queries.contains { $0.contains("Mentions") }, "words inside files are dropped on a server")
        XCTAssertEqual(status.queries, ["“plumber”, “report”"], "never broadened: the request's own words, by name")
        XCTAssertEqual(controller.activeTab?.search?.assist?.coverage, .namesOnly)
        XCTAssertTrue(client.asks.first?.user.contains("\"searching_in\":\"Documents\"") == true)
    }

    func testASearchTheDiskDidntAnswerSaysSoRatherThanNoMatches() async throws {
        standInFanOut()
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\"scan\"]}"), rank: "{\"ranked\": []}")
        let (controller, _) = try await window(client: client)
        // The disk stops answering once the folder is open: the walk and every Spotlight hit's lookup time out.
        let fileSystem = try XCTUnwrap(fileSystems.last)
        fileSystem.isStalled = true
        await searchWithAI(controller, "report")
        let done = await until { controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(done)
        XCTAssertEqual(names(controller), [], "nothing was found")
        let status = try XCTUnwrap(controller.aiSearchStatusForTesting)
        XCTAssertEqual(status.text, AgentText.searchDiskDidntAnswer, "never “0 matches”")
        XCTAssertTrue(fileSystem.lookups.all.contains { $0.path == scan.path }, "a Spotlight hit was looked up")
    }

    func testAPlaceThatIsntRespondingSaysTheDiskDidntAnswerWhenNothingIsFound() async throws {
        AISearchRunner.fanOutAnswersForTesting = { _ in [] }
        let storage = MemoryStorageFactsReader(home: home)
        storage.set(StorageProbe(timedOut: true), under: documents.path)
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\"zebra\"]}"), rank: "{\"ranked\": []}")
        let (controller, _) = try await window(client: client, storage: storage)
        await searchWithAI(controller, "zebra")
        let done = await until { controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(done)
        // The line is the sentence alone: nothing was searched, so "Names only here" has nothing to add.
        XCTAssertEqual(controller.aiSearchStatusForTesting?.text, AgentText.searchDiskDidntAnswer)
    }

    func testASearchThatFindsNothingOnADiskThatAnswersCountsNoMatches() async throws {
        AISearchRunner.fanOutAnswersForTesting = { _ in [] }
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\"zebra\"]}"), rank: "{\"ranked\": []}")
        let (controller, _) = try await window(client: client)
        await searchWithAI(controller, "zebra")
        let done = await until { controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(done)
        let status = try XCTUnwrap(controller.aiSearchStatusForTesting)
        XCTAssertNotEqual(status.text, AgentText.searchDiskDidntAnswer)
        XCTAssertTrue(status.text.hasPrefix("0 matches"), status.text)
    }

    func testTheSparkIsOffAtLaunchWhenAIModeIsOffAndAfterTheSearchCloses() async throws {
        let client = AISearchWindowClient(plan: nil, rank: nil)
        let (off, _) = try await window(client: client, on: false)
        off.setAISearchForTesting(true)
        XCTAssertFalse(off.isAISearchOnForTesting, "no model is ready")
        XCTAssertNil(off.aiSearchStatusForTesting)

        let (controller, _) = try await window(client: client)
        XCTAssertFalse(controller.isAISearchOnForTesting)
        controller.setAISearchForTesting(true)
        XCTAssertTrue(controller.isAISearchOnForTesting)
        controller.typeIntoSearchForTesting("report")
        _ = await until { controller.activeTab?.search != nil }
        if !controller.searchFieldKeyForTesting("escape") { controller.headerSearchClosed() }
        let closed = await until { controller.activeTab?.search == nil }
        XCTAssertTrue(closed)
        await settle(0.2)
        XCTAssertFalse(controller.isAISearchOnForTesting, "off when the search closes")
        // AI mode turning off turns it off too.
        controller.setAISearchForTesting(true)
        XCTAssertTrue(controller.isAISearchOnForTesting)
        controller.dependencies.agent.runtime.setOn(false)
        XCTAssertFalse(controller.isAISearchOnForTesting)
    }

    func testFindWithAITurnsTheSparkOnAndSends() async throws {
        standInFanOut()
        let client = AISearchWindowClient(plan: plan("{\"name_any\": [\"scan\"]}"), rank: "{\"ranked\": []}")
        let (controller, _) = try await window(client: client)
        controller.typeIntoSearchForTesting("zzz-nothing")
        let empty = await until { controller.contentStateForTesting?.buttons.contains { $0.action == .findWithAI } == true }
        XCTAssertTrue(empty, "the no-results page offers Find with AI")
        XCTAssertTrue(client.asks.isEmpty)
        XCTAssertTrue(controller.pressContentButtonForTesting(AgentText.searchToggle))
        XCTAssertTrue(controller.isAISearchOnForTesting)
        let asked = await until { client.asks.first?.user.contains("zzz-nothing") == true }
        XCTAssertTrue(asked, "the same words were sent at once")
        XCTAssertEqual(controller.activeTab?.search?.query.usesAI, true)
        let done = await until { controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(done)
        XCTAssertEqual(names(controller), ["Scan_0042.pdf"])
        XCTAssertFalse(controller.contentStateForTesting?.buttons.contains { $0.action == .findWithAI } ?? false,
                       "an AI search doesn't offer it again")
    }
}

// MARK: The kind row

extension AISearchWindowTests {
    private var photo: URL { documents.appendingPathComponent("report-photo.jpg") }
    private var clip: URL { documents.appendingPathComponent("report-clip.mov") }
    private var choices: [String] { ["Any", "Photo", "Video", "Document", "Folder", "Code", "Audio", "Archive"] }

    /// Escape in the search field, or the Search button's close when the field hasn't the caret, and the search gone.
    private func closeSearch(_ controller: BrowserWindowController) async -> Bool {
        if !controller.searchFieldKeyForTesting("escape") { controller.headerSearchClosed() }
        return await until { controller.activeTab?.search == nil && !controller.isSearchingForTesting }
    }

    func testTheKindRowShowsWhileTheSearchIsOpenSparkOnOrOffAndGoesBackToAnyWhenItCloses() async throws {
        let client = AISearchWindowClient(plan: nil, rank: nil)
        // AI mode off: the field has no spark, and the row is the plain search's.
        let (plain, _) = try await window(client: client, on: false)
        XCTAssertFalse(plain.searchKindRowShownForTesting, "no row while the search is closed")
        plain.typeIntoSearchForTesting("report")
        _ = await until { plain.activeTab?.search != nil }
        XCTAssertEqual(plain.searchFieldMarkForTesting, "magnifier")
        XCTAssertTrue(plain.searchKindRowShownForTesting, "the open search brings the row")
        XCTAssertEqual(plain.searchKindChoicesForTesting, choices)
        XCTAssertEqual(plain.searchKindChosenForTesting, "Any", "Any at first")
        let read = plain.searchKindRowAccessibilityForTesting
        XCTAssertEqual(read.role, .radioGroup)
        XCTAssertEqual(read.label, AgentText.searchKindRow)
        XCTAssertEqual(read.choices.map(\.label), choices)
        XCTAssertTrue(read.choices.allSatisfy { $0.role == .radioButton })
        XCTAssertEqual(read.choices.map(\.chosen), [true] + Array(repeating: false, count: 7), "one choice at a time")
        XCTAssertFalse(plain.aiSearchContentsForTesting.shown, "no Read contents without the spark")
        XCTAssertTrue(plain.chooseSearchKindForTesting("Photo"))
        XCTAssertEqual(plain.searchKindChosenForTesting, "Photo")
        XCTAssertEqual(plain.searchKindRowAccessibilityForTesting.choices.map(\.chosen),
                       [false, true] + Array(repeating: false, count: 6))
        let closedPlain = await closeSearch(plain)
        XCTAssertTrue(closedPlain)
        XCTAssertFalse(plain.searchKindRowShownForTesting, "no row once the search closes")
        XCTAssertEqual(plain.searchKindChosenForTesting, "Any", "back to Any when the search closes")
        plain.beginSearch()
        XCTAssertTrue(plain.searchKindRowShownForTesting, "an empty search has the row too")
        XCTAssertEqual(plain.searchKindChosenForTesting, "Any")

        // AI mode on: the spark on or off keeps the row and its choice; Read contents comes and goes with the spark.
        let (controller, _) = try await window(client: client)
        controller.typeIntoSearchForTesting("report")
        _ = await until { controller.activeTab?.search != nil }
        XCTAssertFalse(controller.isAISearchOnForTesting, "off at launch")
        XCTAssertTrue(controller.searchKindRowShownForTesting, "the row shows with the spark off")
        XCTAssertFalse(controller.aiSearchContentsForTesting.shown)
        XCTAssertTrue(controller.chooseSearchKindForTesting("Photo"))
        controller.setAISearchForTesting(true)
        XCTAssertTrue(controller.searchKindRowShownForTesting)
        XCTAssertEqual(controller.searchKindChosenForTesting, "Photo", "the spark on keeps the kind")
        controller.setAISearchForTesting(false)
        XCTAssertTrue(controller.searchKindRowShownForTesting)
        XCTAssertEqual(controller.searchKindChosenForTesting, "Photo", "and so does the spark off")
        XCTAssertFalse(controller.aiSearchContentsForTesting.shown)

        // Closing the search turns the spark off, and the choice goes back to Any.
        controller.setAISearchForTesting(true)
        XCTAssertTrue(controller.chooseSearchKindForTesting("Video"))
        let closed = await closeSearch(controller)
        XCTAssertTrue(closed)
        await settle(0.2)
        XCTAssertFalse(controller.isAISearchOnForTesting)
        XCTAssertFalse(controller.searchKindRowShownForTesting, "no row once the search closes")
        controller.setAISearchForTesting(true)
        XCTAssertTrue(controller.searchKindRowShownForTesting)
        XCTAssertEqual(controller.searchKindChosenForTesting, "Any", "reset when the search closed")
        // AI mode turning off turns the spark off; the open search keeps its row and its kind.
        XCTAssertTrue(controller.chooseSearchKindForTesting("Audio"))
        controller.dependencies.agent.runtime.setOn(false)
        XCTAssertFalse(controller.isAISearchOnForTesting)
        XCTAssertTrue(controller.searchKindRowShownForTesting)
        XCTAssertEqual(controller.searchKindChosenForTesting, "Audio")
    }

    func testAPlainSearchKeptToAKindFindsThatKindAloneAndTheStatusBarNamesIt() async throws {
        let client = AISearchWindowClient(plan: nil, rank: nil)
        let (controller, memory) = try await window(client: client, on: false)
        for url in [photo, clip] { try await memory.createFileExclusively(at: url, contents: Data([1])) }
        let everyKind = Set(reports + ["report-photo.jpg", "report-clip.mov"])
        controller.typeIntoSearchForTesting("report")
        let typed = await until { controller.activeTab?.search?.query.text == "report" && controller.activeTab?.search?.isGathering == false }
        XCTAssertTrue(typed)
        XCTAssertNil(controller.activeTab?.search?.query.kind)
        XCTAssertEqual(Set(names(controller)), everyKind)
        XCTAssertFalse(controller.statusTextForTesting.contains("Photos"), controller.statusTextForTesting)

        // Photo searches the words on show again, by name, for pictures alone; the status bar names it at its end.
        XCTAssertTrue(controller.chooseSearchKindForTesting("Photo"))
        let photos = await until { controller.activeTab?.search?.query.kind == .image && controller.activeTab?.search?.isGathering == false }
        XCTAssertTrue(photos)
        XCTAssertEqual(controller.activeTab?.search?.query.usesAI, false)
        XCTAssertEqual(names(controller), ["report-photo.jpg"])
        let named = await until { controller.statusTextForTesting.hasSuffix("  •  Photos") }
        XCTAssertTrue(named, controller.statusTextForTesting)
        XCTAssertTrue(controller.statusTextForTesting.hasPrefix("1 result  •  "), controller.statusTextForTesting)
        XCTAssertNil(controller.aiSearchStatusForTesting, "the usual line, not AI search's")

        // Document takes in text files. Any finds every kind again, and the status bar drops the kind.
        XCTAssertTrue(controller.chooseSearchKindForTesting("Document"))
        let documentsFound = await until {
            controller.activeTab?.search?.query.kind == .document && controller.activeTab?.search?.isGathering == false
        }
        XCTAssertTrue(documentsFound)
        XCTAssertEqual(Set(names(controller)), Set(reports))
        let documentsNamed = await until { controller.statusTextForTesting.hasSuffix("  •  Documents") }
        XCTAssertTrue(documentsNamed, controller.statusTextForTesting)
        XCTAssertTrue(controller.chooseSearchKindForTesting("Any"))
        let any = await until { controller.activeTab?.search?.query.kind == nil && controller.activeTab?.search?.isGathering == false }
        XCTAssertTrue(any)
        XCTAssertEqual(Set(names(controller)), everyKind)
        let unnamed = await until { !controller.statusTextForTesting.contains("Documents") }
        XCTAssertTrue(unnamed, controller.statusTextForTesting)
        XCTAssertTrue(client.asks.isEmpty, "nothing is sent")

        // With no words a choice searches nothing, and the empty search stays open; the next words are kept to it.
        let closed = await closeSearch(controller)
        XCTAssertTrue(closed)
        controller.beginSearch()
        XCTAssertTrue(controller.chooseSearchKindForTesting("Video"))
        await settle(0.3)
        XCTAssertNil(controller.activeTab?.search, "no words, no search")
        XCTAssertTrue(controller.isSearchingForTesting)
        controller.typeIntoSearchForTesting("report")
        let videos = await until { controller.activeTab?.search?.query.kind == .video && controller.activeTab?.search?.isGathering == false }
        XCTAssertTrue(videos)
        XCTAssertEqual(names(controller), ["report-clip.mov"])

        // Each tab's search keeps its own kind: a new tab's search starts at Any, and going back shows Video again.
        controller.perform(.newTab)
        let away = await until { controller.activeTab?.search == nil && !controller.isSearchingForTesting }
        XCTAssertTrue(away)
        XCTAssertEqual(controller.searchKindChosenForTesting, "Any")
        controller.perform(.previousTab)
        let back = await until { controller.isSearchingForTesting && controller.activeTab?.search?.query.kind == .video }
        XCTAssertTrue(back)
        XCTAssertTrue(controller.searchKindRowShownForTesting)
        XCTAssertEqual(controller.searchKindChosenForTesting, "Video")
    }

    func testAChosenKindLimitsTheNameMatchesTheModelsPlanAndTheStatusLine() async throws {
        let found = [scan, photo, clip] + forbidden + reports.map { documents.appendingPathComponent($0) }
        AISearchRunner.fanOutAnswersForTesting = { _ in found }
        // The model asks for videos in one query and text files in another. Neither can widen the search past photos.
        let client = AISearchWindowClient(plan: plan("""
            {"name_any": ["report"], "kinds": ["video"]}, {"name_any": ["report"], "extensions": ["txt"]}
            """), rank: "{\"ranked\": []}")
        let (controller, memory) = try await window(client: client)
        for url in [photo, clip] { try await memory.createFileExclusively(at: url, contents: Data([1])) }
        controller.setAISearchForTesting(true)
        XCTAssertTrue(controller.chooseSearchKindForTesting("Photo"))
        controller.typeIntoSearchForTesting("report")
        let typed = await until { controller.activeTab?.search?.query.text == "report" && controller.activeTab?.search?.isGathering == false }
        XCTAssertTrue(typed)
        XCTAssertEqual(controller.activeTab?.search?.query.kind, .image)
        XCTAssertEqual(names(controller), ["report-photo.jpg"], "typing finds names of the chosen kind alone")
        XCTAssertTrue(client.asks.isEmpty, "nothing is sent until Return")

        controller.submitSearchForTesting()
        let done = await until { controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(done)
        XCTAssertEqual(controller.activeTab?.search?.query.kind, .image)
        XCTAssertEqual(names(controller), ["report-photo.jpg"], "no video and no text file, whatever the plan said")
        XCTAssertTrue(client.asks.first?.user.contains("\"only_kind\":\"image\"") == true, "the model is told the kind")
        let status = try XCTUnwrap(controller.aiSearchStatusForTesting)
        XCTAssertEqual(status.text, "1 match · “report” · Photos", "the status bar names the kind once, at its end")
        XCTAssertEqual(status.queries, ["“report”"], "both queries became the same one")

        // Another kind searches the words again by name and sends nothing; Return asks the model again.
        let asked = client.asks.count
        XCTAssertTrue(controller.chooseSearchKindForTesting("Document"))
        let documentsFound = await until {
            controller.activeTab?.search?.query.kind == .document && controller.activeTab?.search?.isGathering == false
        }
        XCTAssertTrue(documentsFound)
        XCTAssertEqual(Set(names(controller)), Set(reports), "document takes in text files")
        XCTAssertEqual(controller.activeTab?.search?.query.usesAI, false)
        await settle(0.4)
        XCTAssertEqual(client.asks.count, asked, "a choice sends nothing")
        XCTAssertEqual(controller.aiSearchStatusForTesting?.text, AgentText.searchHint("Claude"))

        // The spark off keeps the kind and the search on show; the usual status line names the kind.
        let generation = controller.activeTab?.search?.generation
        controller.setAISearchForTesting(false)
        await settle(0.4)
        XCTAssertTrue(controller.searchKindRowShownForTesting)
        XCTAssertEqual(controller.searchKindChosenForTesting, "Document")
        XCTAssertEqual(controller.activeTab?.search?.generation, generation, "nothing is searched again")
        XCTAssertEqual(controller.activeTab?.search?.query.kind, .document)
        XCTAssertEqual(Set(names(controller)), Set(reports))
        XCTAssertNil(controller.aiSearchStatusForTesting)
        XCTAssertTrue(controller.statusTextForTesting.hasSuffix("  •  Documents"), controller.statusTextForTesting)
        // The spark on again keeps it too, and Return asks the model for documents.
        controller.setAISearchForTesting(true)
        XCTAssertEqual(controller.searchKindChosenForTesting, "Document")
        controller.submitSearchForTesting()
        let again = await until { controller.activeTab?.search?.query.usesAI == true && controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(again)
        XCTAssertEqual(controller.activeTab?.search?.query.kind, .document)
        XCTAssertTrue(client.asks.contains { $0.user.contains("\"only_kind\":\"document\"") }, "the model is told the kept kind")
    }

    func testTabTakesTheKeysToTheKindRowWhereArrowsChooseAndEscapeGivesThemBack() async throws {
        let client = AISearchWindowClient(plan: nil, rank: nil)
        let (controller, _) = try await window(client: client)
        controller.setAISearchForTesting(true)
        XCTAssertEqual(controller.focusOwnerForTesting, "search")
        XCTAssertTrue(controller.searchFieldKeyForTesting("tab"))
        XCTAssertEqual(controller.focusOwnerForTesting, "kinds")
        await settle(0.3)
        XCTAssertTrue(controller.isSearchingForTesting, "an empty search stays open while the row has the keys")
        XCTAssertTrue(controller.isAISearchOnForTesting)
        for (key, chosen) in [("right", "Photo"), ("right", "Video"), ("left", "Photo"), ("left", "Any"), ("left", "Any"),
                              ("right", "Photo")] {
            XCTAssertTrue(controller.kindRowKeyForTesting(key), key)
            XCTAssertEqual(controller.searchKindChosenForTesting, chosen, key)
        }
        XCTAssertTrue(controller.kindRowKeyForTesting("escape"))
        XCTAssertEqual(controller.focusOwnerForTesting, "search", "Escape gives the keys back to the field")
        await settle(0.3)
        XCTAssertTrue(controller.isSearchingForTesting)
        XCTAssertEqual(controller.searchKindChosenForTesting, "Photo")
        XCTAssertTrue(controller.searchFieldKeyForTesting("tab"))
        XCTAssertTrue(controller.kindRowKeyForTesting("tab"))
        XCTAssertEqual(controller.focusOwnerForTesting, "search", "and so does Tab")
        // With the spark off the row is still there: Tab, the arrows and Escape work the same.
        controller.setAISearchForTesting(false)
        XCTAssertTrue(controller.searchFieldKeyForTesting("tab"))
        XCTAssertEqual(controller.focusOwnerForTesting, "kinds")
        XCTAssertTrue(controller.kindRowKeyForTesting("right"))
        XCTAssertEqual(controller.searchKindChosenForTesting, "Video")
        XCTAssertTrue(controller.kindRowKeyForTesting("escape"))
        XCTAssertEqual(controller.focusOwnerForTesting, "search")
        await settle(0.3)
        XCTAssertTrue(controller.isSearchingForTesting)

        // AI mode off: the plain search's row takes the keys the same way, and closing the search hands them back.
        let (plain, _) = try await window(client: client, on: false)
        plain.beginSearch()
        XCTAssertTrue(plain.searchFieldKeyForTesting("tab"))
        XCTAssertEqual(plain.focusOwnerForTesting, "kinds")
        XCTAssertTrue(plain.kindRowKeyForTesting("right"))
        XCTAssertEqual(plain.searchKindChosenForTesting, "Photo")
        plain.perform(.newTab)
        let away = await until { !plain.isSearchingForTesting }
        XCTAssertTrue(away)
        await settle(0.3)
        XCTAssertNotEqual(plain.focusOwnerForTesting, "kinds", "a closed search leaves no keys on its row")
        XCTAssertFalse(plain.kindRowKeyForTesting("right"))
    }
}

@MainActor private final class AISearchWindowHost: BrowserWindowHost {
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
}

/// Stands in for Spotlight under the plain search: each search's stream stays open, and the test hands it updates.
final class AISearchWindowSpotlight: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<[URL]>.Continuation] = []
    private(set) var yields = 0
    /// Answers at once that Spotlight found nothing, as a gathering that finished would, and stays open for updates.
    func stream() -> AsyncStream<[URL]> {
        AsyncStream { continuation in
            continuation.yield([])
            lock.lock(); continuations.append(continuation); lock.unlock()
        }
    }
    /// An update to every search still listening.
    func yield(_ urls: [URL]) {
        lock.lock(); let all = continuations; yields += 1; lock.unlock()
        for continuation in all { continuation.yield(urls) }
    }
}

/// A model that answers the two search questions from fixed JSON. A question can be held until the test lets it go;
/// a held question that is cancelled notes it, and gives up unless it is told to ignore cancelling.
final class AISearchWindowClient: AgentModelClient, @unchecked Sendable {
    let providerName = "Claude", destination = "Claude", isLocal = false
    private let lock = NSLock()
    private let answers: [String: Data]
    private var closed: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var recorded: [AgentStructuredAsk] = []
    private var cancels = 0
    var ignoresCancel = false

    init(plan: String?, rank: String?) {
        var answers: [String: Data] = [:]
        if let plan { answers["search_plan"] = Data(plan.utf8) }
        if let rank { answers["search_rank"] = Data(rank.utf8) }
        self.answers = answers
    }

    var asks: [AgentStructuredAsk] { lock.lock(); defer { lock.unlock() }; return recorded }
    var cancelled: Int { lock.lock(); defer { lock.unlock() }; return cancels }
    func reset() { lock.lock(); recorded = []; lock.unlock() }
    func allSentText() -> String { asks.map { [$0.system, $0.user].joined(separator: "\n") }.joined(separator: "\n") }

    func close(_ name: String) { lock.lock(); closed.insert(name); lock.unlock() }
    func open(_ name: String) {
        lock.lock(); closed.remove(name); let held = waiting[name] ?? []; waiting[name] = nil; lock.unlock()
        for continuation in held { continuation.resume() }
    }

    func structured(_ ask: AgentStructuredAsk) async throws -> Data {
        lock.lock(); recorded.append(ask); lock.unlock()
        let name = ask.schemaName
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if closed.contains(name) { waiting[name, default: []].append(continuation); lock.unlock() } else {
                    lock.unlock(); continuation.resume()
                }
            }
        } onCancel: {
            lock.lock(); cancels += 1
            let held = ignoresCancel ? [] : (waiting[name] ?? [])
            if !ignoresCancel { waiting[name] = nil }
            lock.unlock()
            for continuation in held { continuation.resume() }
        }
        if Task.isCancelled, !ignoresCancel { throw CancellationError() }
        guard let answer = answers[name] else { throw AgentFailure.unreadable }
        return answer
    }

    func turn(_ input: AgentTurnInput) -> AsyncThrowingStream<AgentModelEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentFailure.noTools) }
    }
    func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] { [] }
    func models() async throws -> [AgentModelInfo] { [] }
}

/// The in-memory home, with some files carrying macOS's hidden flag, which a name alone can't show.
final class AISearchWindowFileSystem: FileSystem, @unchecked Sendable {
    let base: InMemoryFileSystem
    let flagged: Set<String>
    /// Every item looked up, and whether downloads were off for it.
    let lookups = AISearchWindowLookups()
    private let lock = NSLock()
    private var stalled = false
    init(base: InMemoryFileSystem, flagged: Set<String>) { self.base = base; self.flagged = flagged }

    /// While on, every read fails as timed out, as on a disk that stopped answering.
    var isStalled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stalled }
        set { lock.lock(); stalled = newValue; lock.unlock() }
    }

    private func marked(_ entry: FileEntry) -> FileEntry {
        guard flagged.contains(entry.url.path) else { return entry }
        return FileEntry(url: entry.url, kind: entry.kind, isHidden: true, size: entry.size, modificationDate: entry.modificationDate,
                         volumeIdentifier: entry.volumeIdentifier, objectIdentity: entry.objectIdentity)
    }
    func entry(at url: URL) async throws -> FileEntry {
        lookups.append(path: url.path, downloadsOff: DatalessGuard.isOff)
        if isStalled { throw FileSystemError.timedOut }
        return marked(try await base.entry(at: url))
    }
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        let base = self.base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if self.isStalled { throw FileSystemError.timedOut }
                    for try await batch in base.enumerate(directory, options: options) {
                        continuation.yield(batch.map(self.marked).filter { options.includeHidden || !$0.isHidden })
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func exists(_ url: URL) async -> Bool { await base.exists(url) }
    func mutationPrecondition(at source: URL) async throws -> FileMutationPrecondition { try await base.mutationPrecondition(at: source) }
    func mutate(_ mutation: ConditionalFileMutation, source: URL, requiring precondition: FileMutationPrecondition) async throws -> URL? {
        try await base.mutate(mutation, source: source, requiring: precondition)
    }
    func copyItem(at source: URL, to destination: URL) async throws { try await base.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) async throws { try await base.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws {
        try await base.replaceItem(at: destination, with: temporary, backup: backup)
    }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws {
        try await base.applyDirectoryMetadata(from: source, to: destination)
    }
    func trashItem(at url: URL) async throws -> URL? { try await base.trashItem(at: url) }
    func removeItem(at url: URL) async throws { try await base.removeItem(at: url) }
    func createDirectory(at url: URL) async throws { try await base.createDirectory(at: url) }
    func createFileExclusively(at url: URL, contents: Data) async throws { try await base.createFileExclusively(at: url, contents: contents) }
    func createSymbolicLink(at url: URL, destination: URL) async throws { try await base.createSymbolicLink(at: url, destination: destination) }
    func createAlias(for url: URL, at destination: URL) async throws { try await base.createAlias(for: url, at: destination) }
    func isCaseSensitive(at url: URL) async throws -> Bool { try await base.isCaseSensitive(at: url) }
    func volumeIdentifier(for url: URL) async throws -> String { try await base.volumeIdentifier(for: url) }
    func availableCapacity(of url: URL) async throws -> Int64 { try await base.availableCapacity(of: url) }
}
/// The items a file system was asked about, in order.
final class AISearchWindowLookups: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(path: String, downloadsOff: Bool)] = []
    var all: [(path: String, downloadsOff: Bool)] { lock.lock(); defer { lock.unlock() }; return recorded }
    func append(path: String, downloadsOff: Bool) { lock.lock(); recorded.append((path, downloadsOff)); lock.unlock() }
    func removeAll() { lock.lock(); recorded = []; lock.unlock() }
}
#endif
