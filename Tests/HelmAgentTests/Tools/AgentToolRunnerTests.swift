import XCTest
import HelmCore
@testable import HelmAgent

/// The three tools as a model sees them: listings with pages, levels and caps; what is left out and what is
/// marked; folders that are never entered; places that refuse or stop answering; and arguments read exactly.
final class AgentToolRunnerTests: XCTestCase {
    private let home = "/home/helm"
    private let support = "/home/helm/HelmSupport"

    private struct Rig {
        let disk: MemoryAgentDisk
        let scope: AgentScope
        let runner: AgentToolRunner
        let validator: AgentLoopFakeValidator
        let root: String
    }

    /// A scope whose tab shows `tab` (the home folder by default), and a runner for one request.
    private func rig(limits: AgentLimits = .cloudModel, tab: String? = nil, listSeconds: Double? = nil,
                     _ build: (MemoryAgentDisk) -> Void) async -> Rig {
        let disk = MemoryAgentDisk(home: home)
        build(disk)
        let scope = AgentScope(disk: disk, home: home, supportFolder: support)
        guard case .root(let root) = await scope.setTabFolder(AgentRootInput(fromPerson: tab ?? home, origin: .tab)) else {
            XCTFail("no tab root")
            fatalError()
        }
        await scope.beginRequest(listSeconds: listSeconds)
        let validator = AgentLoopFakeValidator()
        let runner = AgentToolRunner(scope: scope, disk: disk, validator: validator, limits: limits).usingListSeconds(listSeconds)
        return Rig(disk: disk, scope: scope, runner: runner, validator: validator, root: root.alias)
    }

    private var serial = 0
    private func run(_ rig: Rig, _ name: String, _ arguments: String, selected: Set<String> = []) async -> AgentToolOutcome {
        serial += 1
        return await rig.runner.run(AgentToolCall(id: "call_\(serial)", name: name, arguments: Data(arguments.utf8)), selectedPaths: selected)
    }

    private func list(_ rig: Rig, _ folder: String, depth: Int = 1, after: String = "", selected: Set<String> = []) async -> AgentToolOutcome {
        await run(rig, "list_folder", #"{"folder":"\#(folder)","depth":\#(depth),"after":"\#(after)"}"#, selected: selected)
    }

    private func find(_ rig: Rig, _ folder: String, names: [String] = [], kinds: [String] = [], from: String = "", to: String = "",
                      min: Int = 0, max: Int = 0) async -> AgentToolOutcome {
        let words = names.map { "\"\($0)\"" }.joined(separator: ","), kindWords = kinds.map { "\"\($0)\"" }.joined(separator: ",")
        return await run(rig, "find_items", #"{"folder":"\#(folder)","name_any":[\#(words)],"kinds":[\#(kindWords)],"modified_from":"\#(from)","modified_to":"\#(to)","min_bytes":\#(min),"max_bytes":\#(max)}"#)
    }

    private func json(_ outcome: AgentToolOutcome, file: StaticString = #filePath, line: UInt = #line) -> AgentJSON? {
        guard case .result(let text, _, _) = outcome else {
            XCTFail("not a result: \(outcome)", file: file, line: line)
            return nil
        }
        return try? AgentJSON(data: Data(text.utf8))
    }

    private func code(_ outcome: AgentToolOutcome) -> AgentToolCode? {
        if case .error(let code) = outcome { return code }
        return nil
    }

    private func items(_ json: AgentJSON?) -> [AgentJSON] { AgentLoopKit.array(json, "items") }
    private func names(_ json: AgentJSON?) -> [String] { items(json).compactMap { AgentLoopKit.string($0, "name") } }
    private func item(_ json: AgentJSON?, named name: String) -> AgentJSON? { items(json).first { AgentLoopKit.string($0, "name") == name } }
    private func id(_ json: AgentJSON?, of name: String) -> String { AgentLoopKit.string(item(json, named: name), "id") ?? "" }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    // MARK: Pages, levels and caps

    func testPagesCarryOnAfterTheLastIdAndSayHowManyMore() async {
        var limits = AgentLimits.cloudModel
        limits.entriesPerPage = 3
        let rig = await self.rig(limits: limits) { disk in
            for name in ["a", "b", "c", "d", "e", "f", "g"] { disk.addFile(home + "/\(name).txt") }
        }
        let first = json(await list(rig, rig.root))
        XCTAssertEqual(names(first), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(AgentLoopKit.number(first, "more"), 4)
        XCTAssertEqual(AgentLoopKit.string(first, "partial"), "none")
        XCTAssertEqual(AgentLoopKit.string(first, "source"), "folder_listing")
        XCTAssertEqual(AgentLoopKit.string(first, "folder"), rig.root)
        XCTAssertEqual(AgentLoopKit.string(first, "root"), rig.root)
        XCTAssertEqual(AgentLoopKit.string(first, "name"), "Home")
        XCTAssertEqual(AgentLoopKit.string(first, "place"), "this_mac")

        let second = json(await list(rig, rig.root, after: id(first, of: "c.txt")))
        XCTAssertEqual(names(second), ["d.txt", "e.txt", "f.txt"])
        XCTAssertEqual(AgentLoopKit.number(second, "more"), 1)
        let third = json(await list(rig, rig.root, after: id(second, of: "f.txt")))
        XCTAssertEqual(names(third), ["g.txt"])
        XCTAssertEqual(AgentLoopKit.number(third, "more"), 0)
        // The same item keeps its id from page to page.
        let again = json(await list(rig, rig.root))
        XCTAssertEqual(id(again, of: "a.txt"), id(first, of: "a.txt"))
        XCTAssertEqual(rig.runner.namesSent, 10)
        agentEqual(code(await list(rig, rig.root, after: "f999")), .unknown_id)
        agentEqual(code(await list(rig, rig.root, after: rig.root)), .bad_arguments, "a live id that isn't in this listing")
    }

    func testDepthWalksTheLevelsAndHoldsAppearOnlyOnFoldersTheCallListed() async {
        let rig = await self.rig { disk in
            disk.addFile(home + "/Projects/2026/plan.txt")
            disk.addFile(home + "/Projects/notes.txt")
            disk.addFile(home + "/top.txt")
        }
        let one = json(await list(rig, rig.root, depth: 1))
        XCTAssertEqual(names(one), ["Projects", "top.txt"])
        XCTAssertNil(AgentLoopKit.member(item(one, named: "Projects"), "holds"))
        XCTAssertEqual(AgentLoopKit.string(item(one, named: "Projects"), "kind"), "folder")
        XCTAssertEqual(AgentLoopKit.string(item(one, named: "Projects"), "in"), rig.root)

        let two = json(await list(rig, rig.root, depth: 2))
        XCTAssertEqual(names(two), ["Projects", "2026", "notes.txt", "top.txt"])
        let projects = id(two, of: "Projects")
        XCTAssertEqual(AgentLoopKit.number(item(two, named: "Projects"), "holds"), 2)
        XCTAssertNil(AgentLoopKit.member(item(two, named: "2026"), "holds"), "2026 wasn't listed by this call")
        XCTAssertEqual(AgentLoopKit.string(item(two, named: "notes.txt"), "in"), projects)

        let all = json(await list(rig, rig.root, depth: 0))
        XCTAssertEqual(names(all), ["Projects", "2026", "plan.txt", "notes.txt", "top.txt"])
        XCTAssertEqual(AgentLoopKit.number(item(all, named: "2026"), "holds"), 1)
        XCTAssertEqual(AgentLoopKit.string(item(all, named: "plan.txt"), "in"), id(all, of: "2026"))

        let inside = json(await list(rig, projects, depth: 1))
        XCTAssertEqual(names(inside), ["2026", "notes.txt"])
        XCTAssertEqual(AgentLoopKit.string(inside, "name"), "Projects")
        XCTAssertEqual(AgentLoopKit.string(inside, "root"), rig.root)

        for depth in ["9", "-1", "1.5", "\"1\"", "null"] {
            let outcome = await run(rig, "list_folder", #"{"folder":"\#(rig.root)","depth":\#(depth),"after":""}"#)
            XCTAssertEqual(code(outcome), .bad_arguments, depth)
        }
    }

    func testAllLevelsStopsAtThePlacesDepth() async {
        var path = home + "/Drive"
        let rig = await self.rig(tab: home + "/Other") { disk in
            disk.addFolder(home + "/Other")
            for level in 1...8 { path += "/L\(level)" }
            disk.addFile(path + "/deep.txt")
            disk.setProbe(StorageProbe(isLocal: false), under: home + "/Drive")
        }
        guard case .added(let drive) = await rig.scope.folder(for: AgentRootInput(fromPerson: home + "/Drive", origin: .typed)) else {
            return XCTFail("not added")
        }
        let all = json(await list(rig, drive.alias, depth: 0))
        // A server lists four levels at most.
        XCTAssertEqual(names(all), ["L1", "L2", "L3", "L4"])
        XCTAssertEqual(AgentLoopKit.string(all, "place"), "server")
        XCTAssertEqual(AgentLoopKit.string(all, "name"), "Drive")
    }

    func testTheEntryCapOfARequest() async {
        var limits = AgentLimits.cloudModel
        limits.entriesPerRequest = 5
        let rig = await self.rig(limits: limits) { disk in
            for index in 1...4 { disk.addFile(home + "/A/\(index).txt") }
            for index in 1...3 { disk.addFile(home + "/B/\(index).txt") }
        }
        let top = json(await list(rig, rig.root))
        XCTAssertEqual(names(top), ["A", "B"])
        let a = json(await list(rig, id(top, of: "A")))
        XCTAssertEqual(names(a).count, 3, "five entries a request, two already sent")
        XCTAssertEqual(AgentLoopKit.string(a, "partial"), "limit")
        XCTAssertEqual(AgentLoopKit.number(a, "more"), 1)
        agentEqual(code(await list(rig, id(top, of: "B"))), .limit_reached)
        agentEqual(code(await find(rig, rig.root)), .limit_reached)
        XCTAssertEqual(rig.runner.namesSent, 5)
    }

    // MARK: What is left out and what is marked

    func testHiddenSidecarAndLockNamesAndTheHomeLibraryAreLeftOut() async {
        let rig = await self.rig { disk in
            for name in [".DS_Store", "._photo.png", "~$report.docx", ".~lock.sheet.ods#", ".ssh", "photo.png", "flagged.txt"] {
                disk.addFile(home + "/" + name)
            }
            disk.setHidden(home + "/flagged.txt")
            disk.addFolder(home + "/Library/Preferences")
            disk.addFolder(home + "/HelmSupport/cache")
            disk.addFolder(home + "/Visible")
        }
        let listing = json(await list(rig, rig.root, depth: 0))
        XCTAssertEqual(names(listing), ["photo.png", "Visible"])
        XCTAssertFalse(rig.disk.asked.contains { $0.contains("/Library") })
        XCTAssertFalse(rig.disk.asked.contains { $0.contains("HelmSupport/") }, "the support folder is never listed")
        agentEqual(code(await run(rig, "list_folder", #"{"folder":"\#(rig.root)","depth":1,"after":"","extra":1}"#)), .bad_arguments)
    }

    func testCloudSelectedAndPlaceMarks() async {
        let rig = await self.rig { disk in
            disk.addFile(home + "/a.png")
            disk.addFile(home + "/far.mov")
            disk.markCloudOnly(home + "/far.mov")
            disk.addFolder(home + "/Documents/Notes")
            disk.setProbe(StorageProbe(isUbiquitous: true), under: home + "/Documents")
            disk.addFolder(home + "/Plain")
        }
        let listing = json(await list(rig, rig.root, selected: [home + "/a.png"]))
        let png = item(listing, named: "a.png"), movie = item(listing, named: "far.mov")
        XCTAssertEqual(AgentLoopKit.member(png, "selected"), .bool(true))
        XCTAssertNil(AgentLoopKit.member(png, "cloud"))
        XCTAssertEqual(AgentLoopKit.member(movie, "cloud"), .bool(true))
        XCTAssertNil(AgentLoopKit.member(movie, "selected"))
        XCTAssertEqual(AgentLoopKit.string(movie, "kind"), "video")
        XCTAssertEqual(AgentLoopKit.string(item(listing, named: "Documents"), "place"), "icloud")
        XCTAssertNil(AgentLoopKit.member(item(listing, named: "Plain"), "place"))
        XCTAssertNil(AgentLoopKit.member(png, "place"))
        // The note tells which roots hold a file that isn't downloaded.
        let holding = await rig.scope.rootsHoldingCloudOnly()
        XCTAssertEqual(holding, [rig.root])
    }

    func testBytesAreRoundedToTwoFiguresAndDatesAreDays() async {
        let rig = await self.rig { disk in
            disk.addFile(home + "/big.pdf", size: 1_234_567, modified: day(2026, 3, 14))
            disk.addFile(home + "/tiny.txt", size: 99, modified: day(2025, 12, 31))
            disk.addFile(home + "/blob", size: 4_449)
            disk.addFolder(home + "/Folder")
            disk.addLink(home + "/Shortcut", to: home + "/Folder")
        }
        let listing = json(await list(rig, rig.root))
        XCTAssertEqual(AgentLoopKit.number(item(listing, named: "big.pdf"), "bytes"), 1_200_000)
        XCTAssertEqual(AgentLoopKit.string(item(listing, named: "big.pdf"), "modified"), "2026-03-14")
        XCTAssertEqual(AgentLoopKit.string(item(listing, named: "big.pdf"), "kind"), "pdf")
        XCTAssertEqual(AgentLoopKit.number(item(listing, named: "tiny.txt"), "bytes"), 99)
        XCTAssertEqual(AgentLoopKit.string(item(listing, named: "tiny.txt"), "modified"), "2025-12-31")
        XCTAssertEqual(AgentLoopKit.number(item(listing, named: "blob"), "bytes"), 4_400)
        XCTAssertEqual(AgentLoopKit.string(item(listing, named: "blob"), "kind"), "other")
        XCTAssertNil(AgentLoopKit.member(item(listing, named: "Folder"), "bytes"))
        XCTAssertEqual(AgentLoopKit.string(item(listing, named: "Shortcut"), "kind"), "link")
        XCTAssertTrue(id(listing, of: "Shortcut").hasPrefix("f"))
    }

    // MARK: Folders that are never entered

    func testAProtectedFolderUnderAHomeRootIsListedAndNeverEntered() async {
        let rig = await self.rig { disk in
            disk.addFile(home + "/Documents/secret-plans.txt")
            disk.addFile(home + "/Desktop/screen.png")
            disk.addFile(home + "/open.txt")
        }
        let listing = json(await list(rig, rig.root, depth: 0))
        XCTAssertEqual(names(listing), ["Desktop", "Documents", "open.txt"])
        XCTAssertNil(AgentLoopKit.member(item(listing, named: "Documents"), "holds"))
        agentEqual(code(await list(rig, id(listing, of: "Documents"))), .not_allowed)
        agentEqual(code(await find(rig, id(listing, of: "Desktop"))), .not_allowed)
        let found = json(await find(rig, rig.root, names: ["secret", "screen"]))
        XCTAssertTrue(items(found).isEmpty)
        XCTAssertFalse(rig.disk.asked.contains { AgentPathParts.isAt($0, orInside: home + "/Documents") || AgentPathParts.isAt($0, orInside: home + "/Desktop") },
                       "\(rig.disk.asked)")
    }

    func testTheMusicAndTVLibrariesAreLeavesUnderTheFoldersThatHoldThem() async {
        for (tab, library) in [(home + "/Music", "Music"), (home + "/Movies", "TV")] {
            let rig = await self.rig(tab: tab) { disk in
                disk.addFile(tab + "/" + library + "/Media/song.m4a")
                disk.addFile(tab + "/mix.mp3")
            }
            let listing = json(await list(rig, rig.root, depth: 3))
            XCTAssertEqual(Set(names(listing)), [library, "mix.mp3"], tab)
            agentEqual(code(await list(rig, id(listing, of: library))), .not_allowed, tab)
            XCTAssertFalse(rig.disk.asked.contains { AgentPathParts.isAt($0, orInside: tab + "/" + library) }, "\(rig.disk.asked)")
        }
        // The person's own choice of the library itself opens it.
        let rig = await self.rig(tab: home + "/Music/Music") { disk in disk.addFile(home + "/Music/Music/Media/song.m4a") }
        let opened = json(await list(rig, rig.root, depth: 2))
        XCTAssertEqual(names(opened), ["Media", "song.m4a"])
    }

    func testADeniedListingAnswersNotAllowedOnceWithNoSecondDiskCall() async {
        let rig = await self.rig { disk in
            disk.addFile(home + "/Locked/inside.txt")
            disk.markDenied(home + "/Locked")
        }
        let top = json(await list(rig, rig.root))
        let locked = id(top, of: "Locked")
        let askedBefore = rig.disk.asked.filter { $0 == home + "/Locked" }.count
        agentEqual(code(await list(rig, locked)), .not_allowed)
        let askedOnce = rig.disk.asked.filter { $0 == home + "/Locked" }.count
        XCTAssertGreaterThan(askedOnce, askedBefore)
        agentEqual(code(await list(rig, locked)), .not_allowed)
        agentEqual(code(await find(rig, locked)), .not_allowed)
        // A walk from above skips it too.
        _ = await list(rig, rig.root, depth: 0)
        XCTAssertEqual(rig.disk.asked.filter { $0 == home + "/Locked" }.count, askedOnce)
    }

    func testFoldersThatArentLoadedAreCountedAndNeverEntered() async {
        let rig = await self.rig { disk in
            disk.addFolder(home + "/Cloudy")
            disk.markNotLoaded(home + "/Cloudy")
            disk.addFile(home + "/Projects/a.txt")
        }
        let shallow = json(await list(rig, rig.root, depth: 1))
        XCTAssertEqual(AgentLoopKit.number(shallow, "not_loaded"), 0)
        let deep = json(await list(rig, rig.root, depth: 2))
        XCTAssertEqual(AgentLoopKit.number(deep, "not_loaded"), 1)
        XCTAssertEqual(AgentLoopKit.member(item(deep, named: "Cloudy"), "cloud"), .bool(true))
        agentEqual(code(await list(rig, id(deep, of: "Cloudy"))), .not_loaded)
        XCTAssertEqual(rig.runner.notLoaded, 1)
        XCTAssertFalse(rig.disk.asked.contains(home + "/Cloudy"))
    }

    func testASlowRootAnswersPartial() async {
        let rig = await self.rig(tab: home + "/Other", listSeconds: 0.5) { disk in
            disk.addFolder(home + "/Other")
            disk.addFile(home + "/Slow/a.txt")
        }
        guard case .added(let slow) = await rig.scope.folder(for: AgentRootInput(fromPerson: home + "/Slow", origin: .typed)) else {
            return XCTFail("not added")
        }
        rig.disk.setDelay(1, under: home + "/Slow")
        let listing = json(await list(rig, slow.alias))
        XCTAssertEqual(AgentLoopKit.string(listing, "partial"), "slow")
        XCTAssertTrue(items(listing).isEmpty)
        XCTAssertEqual(rig.runner.slowRoot, "Slow")
    }

    // MARK: Arguments

    func testUnknownToolsAndFieldsAndMissingFieldsAreRefused() async {
        let rig = await self.rig { disk in disk.addFile(home + "/a.txt") }
        agentEqual(code(await run(rig, "run_command", #"{"command":"ls"}"#)), .unknown_tool)
        agentEqual(code(await run(rig, "list_folder", #"{"folder":"\#(rig.root)","depth":1}"#)), .bad_arguments)
        agentEqual(code(await run(rig, "list_folder", #"{"folder":"\#(rig.root)","depth":1,"after":"","path":"/"}"#)), .bad_arguments)
        agentEqual(code(await run(rig, "list_folder", "not json")), .bad_arguments)
        agentEqual(code(await run(rig, "list_folder", "[]")), .bad_arguments)
        agentEqual(code(await find(rig, rig.root, kinds: ["executable"])), .bad_arguments)
        agentEqual(code(await find(rig, rig.root, from: "2026-13-01")), .bad_arguments)
        agentEqual(code(await find(rig, rig.root, to: "26-01-01")), .bad_arguments)
        agentEqual(code(await find(rig, rig.root, min: -1)), .bad_arguments)
        agentEqual(code(await run(rig, "find_items", #"{"folder":"\#(rig.root)"}"#)), .bad_arguments)
        agentEqual(code(await run(rig, "propose_changes", #"{"moves":[]}"#)), .bad_arguments)
        XCTAssertTrue(rig.validator.proposed.isEmpty)
    }

    func testAPathOrTildeWhereAnIdBelongsIsAnIdHelmNeverIssued() async {
        let rig = await self.rig { disk in
            disk.addFile(home + "/a.txt")
            disk.addPackage(home + "/Tool.app")
            disk.addFolder(home + "/Folder")
            disk.addLink(home + "/Shortcut", to: home + "/Folder")
        }
        let asked = rig.disk.asked.count
        for folder in [home, "~", "~/Documents", "/", "r1/..", "file:///home/helm", "d1/../.."] {
            agentEqual(code(await list(rig, folder)), .unknown_id, folder)
            agentEqual(code(await find(rig, folder)), .unknown_id, folder)
        }
        XCTAssertEqual(rig.disk.asked.count, asked, "nothing named that way was looked up")
        let listing = json(await list(rig, rig.root))
        agentEqual(code(await list(rig, id(listing, of: "a.txt"))), .not_allowed)
        agentEqual(code(await list(rig, id(listing, of: "Tool.app"))), .inside_package)
        agentEqual(code(await list(rig, id(listing, of: "Shortcut"))), .link)

        let folder = id(listing, of: "Folder")
        await rig.scope.startOver()
        agentEqual(code(await list(rig, folder)), .stale_id)
    }

    // MARK: find_items

    func testFindMatchesNamesKindsDatesAndSizes() async {
        var limits = AgentLimits.cloudModel
        limits.findResults = 2
        let rig = await self.rig(limits: limits) { disk in
            disk.addFile(home + "/Taxes/Invoice-March.pdf", size: 410_000, modified: day(2026, 3, 14))
            disk.addFile(home + "/Taxes/invoice-april.PDF", size: 2_000_000, modified: day(2026, 4, 2))
            disk.addFile(home + "/Taxes/Résumé.docx", size: 50_000, modified: day(2025, 1, 5))
            disk.addFile(home + "/Pictures/beach.png", size: 3_000_000, modified: day(2026, 3, 20))
            disk.addFile(home + "/old.txt", size: 10, modified: day(2020, 1, 1))
        }
        let invoices = json(await find(rig, rig.root, names: ["INVOICE"]))
        XCTAssertEqual(names(invoices), ["invoice-april.PDF", "Invoice-March.pdf"])
        XCTAssertEqual(AgentLoopKit.string(invoices, "source"), "found_items")
        let taxes = id(json(await list(rig, rig.root)), of: "Taxes")
        XCTAssertEqual(AgentLoopKit.string(item(invoices, named: "Invoice-March.pdf"), "in"), taxes)
        agentEqual(names(json(await find(rig, rig.root, names: ["resume"]))), ["Résumé.docx"])
        agentEqual(names(json(await find(rig, rig.root, kinds: ["image"]))), ["beach.png"])
        let documents = json(await find(rig, rig.root, kinds: ["document"]))
        XCTAssertEqual(names(documents).count, 2)
        XCTAssertEqual(names(documents), ["old.txt", "invoice-april.PDF"])
        XCTAssertEqual(AgentLoopKit.number(documents, "more"), 2, "two results at most, four documents: text and pdf count")
        agentEqual(names(json(await find(rig, rig.root, from: "2026-03-15", to: "2026-04-30"))), ["beach.png", "invoice-april.PDF"])
        agentEqual(names(json(await find(rig, rig.root, min: 1_000_000, max: 2_500_000))), ["invoice-april.PDF"])
        agentEqual(names(json(await find(rig, rig.root, names: ["Taxes"], min: 1))), [], "a folder has no size")
        agentEqual(names(json(await find(rig, rig.root, names: ["Taxes"]))), ["Taxes"])
    }

    // MARK: propose_changes

    func testProposalsGoToTheValidator() async {
        let rig = await self.rig { disk in disk.addFile(home + "/a.txt") }
        let empty = #"{"new_folders":[],"moves":[{"items":["f1"],"all_in":"","to":"d2"}],"copies":[],"renames":[],"trash":[]}"#
        guard case .plan = await run(rig, "propose_changes", empty) else { return XCTFail("no plan") }
        XCTAssertEqual(rig.validator.proposed.first?.moves.first?.items, ["f1"])

        rig.validator.answer(.refused(.too_many), .nothingToDo(leftOut: [.not_downloaded: 12, .outside_scope: 0]))
        agentEqual(code(await run(rig, "propose_changes", empty)), .too_many)
        let nothing = json(await run(rig, "propose_changes", empty))
        XCTAssertEqual(AgentLoopKit.string(nothing, "status"), "nothing_to_do")
        XCTAssertEqual(AgentLoopKit.array(nothing, "left_out"), [.object(["code": .string("not_downloaded"), "count": .number(12)])])
    }

    // MARK: Roots that change while they are read

    /// A scope on a disk that can run a step while a listing waits on it, with the tab on `tab`.
    private func hookedRig(tab: String, _ build: (MemoryAgentDisk) -> Void) async -> (rig: Rig, disk: AgentLoopHookedDisk) {
        let memory = MemoryAgentDisk(home: home)
        build(memory)
        let disk = AgentLoopHookedDisk(inner: memory)
        let scope = AgentScope(disk: disk, home: home, supportFolder: support)
        guard case .root(let root) = await scope.setTabFolder(AgentRootInput(fromPerson: tab, origin: .tab)) else {
            XCTFail("no tab root")
            fatalError()
        }
        await scope.beginRequest(listSeconds: nil)
        let validator = AgentLoopFakeValidator()
        let runner = AgentToolRunner(scope: scope, disk: disk, validator: validator, limits: .cloudModel)
        return (Rig(disk: memory, scope: scope, runner: runner, validator: validator, root: root.alias), disk)
    }

    func testATabThatMovesOnWhileItsRootIsListedAnswersStale() async {
        let (rig, disk) = await hookedRig(tab: home) { disk in
            disk.addFile(home + "/Work/report.pdf")
            disk.addFolder("/Volumes/Disk/Work")
        }
        let scope = rig.scope
        agentEqual(await scope.record(for: rig.root)?.name, "Home", "a root's record carries the model's name for it")
        disk.whileListing(home) { _ = await scope.setTabFolder(AgentRootInput(fromPerson: "/Volumes/Disk/Work", origin: .tab)) }
        agentEqual(code(await list(rig, rig.root, depth: 2)), .stale_id)
        agentNil(await scope.record(for: rig.root))

        let (other, otherDisk) = await hookedRig(tab: home) { disk in
            disk.addFile(home + "/report.pdf")
            disk.addFolder("/Volumes/Disk/Work")
        }
        let otherScope = other.scope
        otherDisk.whileListing(home) { _ = await otherScope.setTabFolder(AgentRootInput(fromPerson: "/Volumes/Disk/Work", origin: .tab)) }
        agentEqual(code(await find(other, other.root, names: ["report"])), .stale_id)
    }

    func testARootReplacedByALinkThatKeepsItsIdIsStale() async {
        let share = "/Volumes/Share/Team"
        let (rig, disk) = await hookedRig(tab: share) { disk in
            disk.addFile(share + "/notes.txt")
            disk.addFile(home + "/Private/secret-plans.txt")
        }
        await disk.pinIdentity(of: share)
        let before = json(await list(rig, rig.root))
        XCTAssertEqual(names(before), ["notes.txt"])
        rig.disk.remove(share)
        rig.disk.addLink(share, to: home + "/Private")
        agentEqual(code(await list(rig, rig.root)), .stale_id)
        agentNil(await rig.scope.recheckRoot(alias: rig.root))
    }
}
