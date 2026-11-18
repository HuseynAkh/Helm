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

/// AI search with Read contents on, in a real window on an in-memory home: the files the model looks at and in what
/// order, the pictures that go with them, the files it says fit shown first with what it saw, a file it says doesn't
/// fit losing what was read on this Mac, the status bar's count, and what happens when a provider turns pictures away
/// or a look fails. The reader is a stand-in that answers fixed summaries, with pictures when asked for them.
@MainActor final class AISearchLookWindowTests: XCTestCase {
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []
    private let home = URL(fileURLWithPath: "/home/aisearch-look", isDirectory: true)
    private var pictures: URL { home.appendingPathComponent("Pictures", isDirectory: true) }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        let spotlight = AISearchWindowSpotlight()
        HostEffectRunner.spotlightAnswersForTesting = { _ in spotlight.stream() }
        AISearchRunner.fanOutAnswersForTesting = { _ in [] }
    }
    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers = []; keep = []
        HostEffectRunner.spotlightAnswersForTesting = nil
        AISearchRunner.fanOutAnswersForTesting = nil
        HeaderMotion.isDisabledForTesting = false
        super.tearDown()
    }

    // MARK: The window

    /// Pictures, oldest first: a note, a beach video, a photo Vision labels "kite", a photo of a kite whose name says
    /// nothing and whose label doesn't name it, and a list whose name says kite.
    private let files = ["notes.txt", "beach.mov", "IMG_0042.jpg", "DSC_0193.jpg", "kite-list.txt"]

    private func window(client: AISearchLookClient, reader: AISearchLookReader,
                        files: [String]? = nil) async throws -> (BrowserWindowController, AgentRuntime) {
        let env = try await AppEnvironment.test(home: home)
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        try await memory.createDirectory(at: pictures)
        for name in files ?? self.files {
            try await memory.createFileExclusively(at: pictures.appendingPathComponent(name), contents: Data(name.utf8))
        }
        let operations = OperationCoordinator(fileSystem: memory, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        let secrets = MemorySecretStore()
        let parts = AgentRuntimeParts(secrets: secrets, disk: MemoryAgentDisk(home: home.path), home: home.path,
                                      supportFolder: home.appendingPathComponent(".support").path, clock: env.clock,
                                      buildStamp: "", scripted: client)
        let runtime = AgentRuntime(parts: parts)
        runtime.setOn(true)
        let agent = AgentServices(runtime: runtime, config: AIConfigStore(), secrets: secrets, disk: MemoryAgentDisk(home: home.path),
                                  storage: MemoryStorageFactsReader(home: home), connector: MemoryServerConnector(),
                                  contents: reader)
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: memory,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.ai-look.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith, agent: agent)
        let host = AISearchLookHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "ai-look", seeds: [], activeIndex: 0)
        keep += [host, operations, volumes, runtime]
        controllers.append(controller)
        controller.perform(.list)
        controller.navigate(to: .directory(pictures))
        let arrived = await until { controller.activeTab?.location == .directory(self.pictures) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "Pictures never opened")
        return (controller, runtime)
    }

    private func until(_ timeout: TimeInterval = 30, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    private func names(_ controller: BrowserWindowController) -> [String] {
        guard let tab = controller.activeTab else { return [] }
        return tab.snapshot.sortedEntries.prefix(tab.snapshot.rootCount).map(\.name)
    }

    /// The spark and Read contents on, the words typed, then Return; waits until the model is done with this search.
    private func searchReadingContents(_ controller: BrowserWindowController, _ client: AISearchLookClient, _ text: String) async {
        let planned = client.plans
        controller.setAISearchForTesting(true)
        if !controller.aiSearchContentsForTesting.on { XCTAssertTrue(controller.clickAISearchContentsForTesting()) }
        XCTAssertTrue(controller.aiSearchContentsForTesting.on)
        controller.typeIntoSearchForTesting(text)
        _ = await until { controller.activeTab?.search?.query.text == text && controller.activeTab?.search?.isGathering == false }
        controller.submitSearchForTesting()
        let done = await until {
            client.plans > planned && controller.activeTab?.search?.query.usesAI == true
                && controller.activeTab?.search?.assist?.phase == .done
        }
        XCTAssertTrue(done, "the search never finished")
    }

    private let kitePlan = """
        {"sort": "relevance", "queries": [{"content_all": ["kite"]}, {"name_any": ["kite"]}]}
        """

    // MARK: Looking

    func testTheModelLooksAtWhatWasReadAndWhatItSaysFitsComesFirstWithWhatItSaw() async throws {
        let client = AISearchLookClient(plan: kitePlan) { names in
            AISearchLookClient.answer(names, fits: ["DSC_0193.jpg": "A red kite in a blue sky", "kite-list.txt": "A list of kites to buy"],
                                      misses: ["IMG_0042.jpg"], order: ["DSC_0193.jpg", "IMG_0042.jpg", "kite-list.txt"])
        }
        let reader = AISearchLookReader()
        let (controller, _) = try await window(client: client, reader: reader)
        await searchReadingContents(controller, client, "kite")

        // What was looked at: the label's match first, then the file found by name, then the newest.
        let look = try XCTUnwrap(client.looks.first)
        XCTAssertEqual(client.looks.count, 1)
        XCTAssertEqual(AISearchLookClient.items(in: look), ["IMG_0042.jpg", "kite-list.txt", "DSC_0193.jpg", "beach.mov", "notes.txt"])
        XCTAssertEqual(look.pictures.map(\.label), ["Item 1", "Item 3", "Item 4, frame 1", "Item 4, frame 2", "Item 4, frame 3"])
        XCTAssertTrue(look.user.contains("Kites to buy"), "a document's first lines")
        XCTAssertFalse(client.sentText.contains(home.path), "never a path")
        // Every file was read once without pictures; the pictures and the video again with them.
        XCTAssertEqual(Set(reader.asked(pictures: false)), Set(files))
        XCTAssertEqual(Set(reader.asked(pictures: true)), ["IMG_0042.jpg", "DSC_0193.jpg", "beach.mov"])

        // The fits first, in the model's order, each with what it saw. The photo it said doesn't fit was a match only
        // for its label, so it is a match no more.
        XCTAssertEqual(names(controller), ["DSC_0193.jpg", "kite-list.txt"])
        let listed = await until { controller.matchReasonForTesting(named: "DSC_0193.jpg") != nil }
        XCTAssertTrue(listed)
        XCTAssertEqual(controller.matchReasonForTesting(named: "DSC_0193.jpg"), "Model saw: A red kite in a blue sky")
        XCTAssertEqual(controller.matchReasonForTesting(named: "kite-list.txt"), "Model saw: A list of kites to buy")
        XCTAssertEqual(controller.aiSearchStatusForTesting?.text, "2 matches · Mentions “kite” · Looked at 5")

        // A second search reads nothing again: the memo holds the words and the pictures.
        reader.reset()
        controller.submitSearchForTesting()
        let again = await until { client.looks.count == 2 && controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(again)
        XCTAssertEqual(reader.asked(pictures: false) + reader.asked(pictures: true), [])
        XCTAssertEqual(client.looks[1].pictures.count, 5, "the memo's pictures go again")
    }

    func testFitsComeInQuestionOrderTwelveFilesAQuestion() async throws {
        let numbered = (1...30).map { String(format: "p%02d.jpg", $0) }
        // Fits are every fifth picture, which the model names last first; the first question answers last.
        let client = AISearchLookClient(plan: """
            {"sort": "relevance", "queries": [{"content_all": ["kite"], "kinds": ["image"]}]}
            """, slowWhenShown: "p30.jpg") { names in
            let fits = names.filter { Int($0.dropFirst().prefix(2))! % 5 == 0 }
            return AISearchLookClient.answer(names, fits: Dictionary(uniqueKeysWithValues: fits.map { ($0, "A kite") }),
                                             misses: [], order: fits.reversed())
        }
        let (controller, _) = try await window(client: client, reader: AISearchLookReader(), files: numbered)
        await searchReadingContents(controller, client, "kite")
        XCTAssertEqual(client.looks.map { AISearchLookClient.items(in: $0).count }.sorted(), [6, 12, 12], "three questions")
        XCTAssertEqual(names(controller), ["p20.jpg", "p25.jpg", "p30.jpg", "p10.jpg", "p15.jpg", "p05.jpg"])
        XCTAssertEqual(controller.aiSearchStatusForTesting?.text.hasSuffix(" · Looked at 30"), true,
                       controller.aiSearchStatusForTesting?.text ?? "")
    }

    func testAModelOnThisMacLooksAtTwelve() async throws {
        let numbered = (1...30).map { String(format: "p%02d.jpg", $0) }
        let client = AISearchLookClient(plan: """
            {"sort": "relevance", "queries": [{"content_all": ["kite"], "kinds": ["image"]}]}
            """, isLocal: true) { names in AISearchLookClient.answer(names, fits: [:], misses: [], order: []) }
        let (controller, _) = try await window(client: client, reader: AISearchLookReader(), files: numbered)
        await searchReadingContents(controller, client, "kite")
        XCTAssertEqual(client.looks.count, 1)
        XCTAssertEqual(AISearchLookClient.items(in: client.looks[0]).first, "p30.jpg", "the newest first")
        XCTAssertEqual(controller.aiSearchStatusForTesting?.text.hasSuffix(" · Looked at 12"), true,
                       controller.aiSearchStatusForTesting?.text ?? "")
    }

    // MARK: What the model may look at

    func testASearchOfTheWholeMacLooksOnlyAtWhatThisMacMatchedOrASearchFound() async throws {
        // Spotlight stands in: the name query finds the list; the pictures and videos a query describes are every file.
        let everything = files.map { pictures.appendingPathComponent($0) }
        let list = pictures.appendingPathComponent("kite-list.txt")
        AISearchRunner.fanOutAnswersForTesting = { query in
            if !query.nameAny.isEmpty { return [list] }
            return query.contentAll.isEmpty ? everything : []
        }
        let client = AISearchLookClient(plan: kitePlan) { names in
            AISearchLookClient.answer(names, fits: ["IMG_0042.jpg": "A kite on a beach"], misses: [], order: ["IMG_0042.jpg"])
        }
        let reader = AISearchLookReader()
        let (controller, _) = try await window(client: client, reader: reader)
        controller.setAISearchForTesting(true)
        controller.setSearchScopeForTesting(everywhere: true)
        await searchReadingContents(controller, client, "kite")
        XCTAssertEqual(controller.activeTab?.search?.query.scope, .thisMac)

        // The photo whose label matched, then the list found by name. The newest photo and the video are read on this
        // Mac to be matched, and neither matched, so neither is sent; the note isn't a picture or a video.
        let look = try XCTUnwrap(client.looks.first)
        XCTAssertEqual(AISearchLookClient.items(in: look), ["IMG_0042.jpg", "kite-list.txt"])
        XCTAssertEqual(look.pictures.map(\.label), ["Item 1"])
        XCTAssertFalse(client.sentText.contains("DSC_0193"))
        XCTAssertFalse(client.sentText.contains("beach.mov"))
        XCTAssertEqual(Set(reader.asked(pictures: false)), ["IMG_0042.jpg", "DSC_0193.jpg", "beach.mov", "kite-list.txt"])
        XCTAssertEqual(reader.asked(pictures: true), ["IMG_0042.jpg"])
        XCTAssertEqual(controller.aiSearchStatusForTesting?.text.hasSuffix(" · Looked at 2"), true,
                       controller.aiSearchStatusForTesting?.text ?? "")
        XCTAssertEqual(names(controller).first, "IMG_0042.jpg")
    }

    func testCodeAndSettingsAreLookedAtOnlyWhenThePersonChoosesCode() async throws {
        let client = AISearchLookClient(plan: """
            {"sort": "relevance", "queries": [{"content_all": ["kite"]}]}
            """) { names in AISearchLookClient.answer(names, fits: [:], misses: [], order: []) }
        let reader = AISearchLookReader()
        let (controller, _) = try await window(client: client, reader: reader,
                                               files: ["notes.txt", "kite.swift", "kite.json", "DSC_0193.jpg"])
        await searchReadingContents(controller, client, "kite")
        XCTAssertEqual(Set(AISearchLookClient.items(in: try XCTUnwrap(client.looks.last))), ["notes.txt", "DSC_0193.jpg"])
        XCTAssertFalse(reader.asked(pictures: false).contains("kite.swift"), "never read for a search of any kind")
        XCTAssertFalse(reader.asked(pictures: false).contains("kite.json"))

        XCTAssertTrue(controller.chooseSearchKindForTesting("Code"))
        if !controller.aiSearchContentsForTesting.on { XCTAssertTrue(controller.clickAISearchContentsForTesting()) }
        let looked = client.looks.count
        controller.submitSearchForTesting()
        let done = await until { client.looks.count > looked && controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(done)
        XCTAssertEqual(controller.activeTab?.search?.query.kind, .code)
        XCTAssertEqual(AISearchLookClient.items(in: try XCTUnwrap(client.looks.last)), ["kite.swift"])
    }

    // MARK: When the look goes wrong

    func testAProviderThatTurnsPicturesAwayIsAskedInWordsAndGetsNoPicturesUntilAIModeChanges() async throws {
        let client = AISearchLookClient(plan: kitePlan, refusesPictures: true) { names in
            AISearchLookClient.answer(names, fits: ["DSC_0193.jpg": "A red kite"], misses: [], order: ["DSC_0193.jpg"])
        }
        let reader = AISearchLookReader()
        let (controller, runtime) = try await window(client: client, reader: reader)
        await searchReadingContents(controller, client, "kite")
        XCTAssertEqual(client.looks.map(\.pictures.count), [5, 0], "asked again in words alone")
        XCTAssertTrue(client.looks[1].user.contains("\"shows\":[\"kite\"]"), "the words found on this Mac stand in")
        XCTAssertEqual(names(controller).first, "DSC_0193.jpg")
        XCTAssertEqual(controller.matchReasonForTesting(named: "DSC_0193.jpg"), "Model saw: A red kite")
        XCTAssertEqual(controller.aiSearchRunner?.picturesRefused, true)

        // The next search sends no pictures and makes none.
        reader.reset()
        controller.submitSearchForTesting()
        let again = await until { client.looks.count == 3 && controller.activeTab?.search?.assist?.phase == .done }
        XCTAssertTrue(again)
        XCTAssertEqual(client.looks[2].pictures.count, 0)
        XCTAssertEqual(reader.asked(pictures: true), [])

        // AI mode off and on: pictures go again.
        runtime.setOn(false)
        runtime.setOn(true)
        XCTAssertEqual(controller.aiSearchRunner?.picturesRefused, false)
        await searchReadingContents(controller, client, "kite")
        XCTAssertEqual(client.looks.count, 5)
        XCTAssertEqual(client.looks[3].pictures.count, 5)
    }

    /// A model its provider listed as reading text only, as LM Studio says of gpt-oss, is shown Apple's descriptions
    /// from the first look, and no picture is even made for it. Choosing a model that sees pictures sends them again.
    func testAModelThatCantSeePicturesGetsWordsFromTheFirstLook() async throws {
        let client = AISearchLookClient(plan: kitePlan) { names in
            AISearchLookClient.answer(names, fits: ["DSC_0193.jpg": "A red kite"], misses: [], order: ["DSC_0193.jpg"])
        }
        let reader = AISearchLookReader()
        let (controller, runtime) = try await window(client: client, reader: reader)
        var config = AIConfig(provider: "lmStudio", models: ["lmStudio": "openai/gpt-oss-20b"],
                              textOnlyModels: ["lmStudio|127.0.0.1:1234": ["openai/gpt-oss-20b"]])
        runtime.configure(config)
        XCTAssertFalse(runtime.modelSeesPictures)
        await searchReadingContents(controller, client, "kite")
        XCTAssertEqual(client.looks.map(\.pictures.count), [0], "asked once, in words")
        XCTAssertTrue(client.looks[0].user.contains("\"shows\":[\"kite\"]"), "the words found on this Mac stand in")
        XCTAssertEqual(reader.asked(pictures: true), [], "no picture was made")
        XCTAssertEqual(names(controller).first, "DSC_0193.jpg")
        XCTAssertEqual(controller.aiSearchRunner?.picturesRefused, false, "nothing was turned away")

        config.models["lmStudio"] = "qwen2.5-vl-7b-instruct"
        runtime.configure(config)
        reader.reset()
        await searchReadingContents(controller, client, "kite")
        XCTAssertEqual(client.looks.last?.pictures.count, 5)
    }

    func testALookThatFailsKeepsWhatWasReadOnThisMac() async throws {
        let client = AISearchLookClient(plan: kitePlan) { _ in throw AgentFailure.timedOut }
        let (controller, _) = try await window(client: client, reader: AISearchLookReader())
        await searchReadingContents(controller, client, "kite")
        XCTAssertEqual(client.looks.count, 1)
        XCTAssertEqual(Set(names(controller)), ["IMG_0042.jpg", "kite-list.txt"])
        let listed = await until { controller.matchReasonForTesting(named: "IMG_0042.jpg") != nil }
        XCTAssertTrue(listed)
        XCTAssertEqual(controller.matchReasonForTesting(named: "IMG_0042.jpg"), "Shows: kite")
        XCTAssertEqual(controller.aiSearchStatusForTesting?.text.contains("Looked at"), false, "nothing was looked at")
        let status = controller.aiSearchStatusForTesting?.text ?? ""
        XCTAssertTrue(status.contains("Couldn't look at ") && status.hasSuffix("took too long to answer"), "the status bar says why: \(status)")
        XCTAssertEqual(controller.aiSearchRunner?.picturesRefused, false, "only a bad request turns pictures off")
    }
}

@MainActor private final class AISearchLookHost: BrowserWindowHost {
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
}

/// Read contents' stand-in: fixed words for each file by its name, and a small picture for a picture, three frames
/// for a video, when pictures are asked for. It notes every file it is asked about and whether pictures were wanted.
final class AISearchLookReader: AgentContentReading, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AgentContentRequest] = []

    func asked(pictures: Bool) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.wantsImages == pictures }.map(\.name)
    }
    func reset() { lock.lock(); requests = []; lock.unlock() }

    func summaries(of requests: [AgentContentRequest], permit: AgentContentPermit, seconds: Double) async -> [AgentContentSummary] {
        lock.lock(); self.requests += requests; lock.unlock()
        return requests.map { request in
            let name = request.name, ext = (name as NSString).pathExtension
            func image(_ source: AgentContentImage.Source) -> AgentContentImage {
                AgentContentImage(jpeg: Data((name + "\(source)").utf8), width: 512, height: 384, source: source)
            }
            switch ext {
            case "jpg":
                let label = name == "IMG_0042.jpg" ? "kite" : "sky"
                return AgentContentSummary(kind: .image, status: .read, labels: [AgentContentLabel(identifier: label, confidence: 0.9)],
                                           images: request.wantsImages ? [image(.picture)] : [])
            case "mov":
                return AgentContentSummary(kind: .video, status: .read, labels: [AgentContentLabel(identifier: "beach", confidence: 0.9)],
                                           seconds: 9, frames: 3,
                                           images: request.wantsImages ? [0, 4, 8].map { image(.frame(seconds: $0)) } : [])
            default:
                return AgentContentSummary(kind: .text, status: .read, lines: name == "kite-list.txt" ? ["Kites to buy"] : ["Groceries"])
            }
        }
    }
}

/// A model that plans and ranks from fixed JSON and answers each look question with `look`, given the names of the
/// items shown, in order. It can turn away a look that carries pictures as a bad request, and hold the look that shows
/// a given file a moment, so another question answers first.
final class AISearchLookClient: AgentModelClient, @unchecked Sendable {
    let providerName = "Claude", destination = "Claude"
    let isLocal: Bool
    private let lock = NSLock()
    private let plan: String
    private let refusesPictures: Bool
    private let slowWhenShown: String?
    private let look: @Sendable ([String]) throws -> String
    private var recorded: [AgentStructuredAsk] = []

    init(plan: String, isLocal: Bool = false, refusesPictures: Bool = false, slowWhenShown: String? = nil,
         look: @escaping @Sendable ([String]) throws -> String) {
        self.plan = plan; self.isLocal = isLocal; self.refusesPictures = refusesPictures; self.slowWhenShown = slowWhenShown
        self.look = look
    }

    var plans: Int {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.schemaName == "search_plan" }.count
    }
    var looks: [AgentStructuredAsk] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.schemaName == "search_look" }
    }
    var sentText: String {
        lock.lock(); defer { lock.unlock() }
        return recorded.map { [$0.system, $0.user].joined(separator: "\n") }.joined(separator: "\n")
    }

    /// The names of the items a look question shows, in order.
    static func items(in ask: AgentStructuredAsk) -> [String] {
        ask.user.split(separator: "\n").filter { $0.hasPrefix("{") }.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))).flatMap { ($0 as? [String: Any])?["name"] as? String }
        }
    }

    /// An answer that names the items in `order`: each in `fits` fits with what was seen, each in `misses` doesn't.
    static func answer(_ names: [String], fits: [String: String], misses: Set<String>, order: [String]) -> String {
        var items: [[String: Any]] = []
        for name in order {
            guard let index = names.firstIndex(of: name) else { continue }
            if let seen = fits[name] { items.append(["item": index + 1, "fits": true, "seen": seen]) }
            if misses.contains(name) { items.append(["item": index + 1, "fits": false, "seen": ""]) }
        }
        let data = try? JSONSerialization.data(withJSONObject: ["items": items])
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    func structured(_ ask: AgentStructuredAsk) async throws -> Data {
        lock.lock(); recorded.append(ask); lock.unlock()
        switch ask.schemaName {
        case "search_plan": return Data(plan.utf8)
        case "search_rank": return Data("{\"ranked\": []}".utf8)
        case "search_look":
            if refusesPictures, !ask.pictures.isEmpty { throw AgentFailure.badRequest }
            let names = Self.items(in: ask)
            if let slowWhenShown, names.contains(slowWhenShown) { try? await Task.sleep(nanoseconds: 400_000_000) }
            return Data(try look(names).utf8)
        default: throw AgentFailure.unreadable
        }
    }

    func turn(_ input: AgentTurnInput) -> AsyncThrowingStream<AgentModelEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentFailure.noTools) }
    }
    func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] { [] }
    func models() async throws -> [AgentModelInfo] { [] }
}
#endif
