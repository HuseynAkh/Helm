#if os(macOS)
import AppKit
import XCTest
import HelmAgent
import HelmCore
@testable import HelmUI

/// An approved plan becomes file commands in the order they can run: the new folders a ticked step needs, parents
/// first; one batch of renames for each folder; one move and one copy for each destination; the Trash last. Groups
/// left unticked compile to nothing, and every item carries the identity and kind the plan was checked with.
final class AgentPlanCompilerTests: XCTestCase {
    private let root = "/home/helm/Downloads"
    private var docs: AgentPlanItem { item("/home/helm/Documents", kind: .directory, handle: "d1") }
    private var rootItem: AgentPlanItem { item(root, kind: .directory, handle: "r1") }

    private func item(_ path: String, kind: FileEntryKind = .regular, handle: String) -> AgentPlanItem {
        AgentPlanItem(handle: handle, rootAlias: "r1", path: path, name: (path as NSString).lastPathComponent, kind: kind,
                      identity: FileObjectIdentity(scope: "disk", object: handle), isDataless: false)
    }
    private func name(_ text: String) -> ValidFileName { ValidFileName(text)! }
    private func source(_ item: AgentPlanItem) -> AgentCompiledSource {
        AgentCompiledSource(url: URL(fileURLWithPath: item.path, isDirectory: item.kind == .directory),
                            identity: item.identity, kind: item.kind)
    }

    private lazy var a = item(root + "/a.png", handle: "f1")
    private lazy var b = item(root + "/b.png", handle: "f2")
    private lazy var c = item(root + "/c.txt", handle: "f3")
    private lazy var d = item(root + "/d.txt", handle: "f4")
    private lazy var f = item(root + "/Sub/f.txt", handle: "f5")
    private lazy var h = item(root + "/h.txt", handle: "f6")
    private lazy var old = item(root + "/old.tmp", handle: "f7")
    private lazy var j = item(root + "/Reports", kind: .directory, handle: "d8")
    private lazy var k = item(root + "/k.txt", handle: "f9")

    /// Twelve steps in eight groups. Images (n1) holds 2026 (n2); Unused (n3) is a group of new folders on its own.
    private lazy var plan: AgentChangePlan = {
        let steps: [AgentPlanStep] = [
            .newFolder(key: "n1", parent: .existing(rootItem), name: name("Images")),   // 0
            .newFolder(key: "n2", parent: .new(key: "n1"), name: name("2026")),         // 1
            .move(a, to: .new(key: "n2")),                                               // 2
            .move(b, to: .new(key: "n1")),                                               // 3
            .copy(c, to: .existing(docs)),                                               // 4
            .rename(d, to: name("e.txt")),                                               // 5
            .rename(f, to: name("g.txt")),                                               // 6
            .rename(h, to: name("i.txt")),                                               // 7
            .trash(old),                                                                 // 8
            .newFolder(key: "n3", parent: .existing(rootItem), name: name("Unused")),   // 9
            .move(j, to: .existing(docs)),                                               // 10
            .copy(k, to: .new(key: "n1"))                                                // 11
        ]
        let groups = [
            AgentPlanGroup(id: 0, kind: .newFolders, steps: [9]),
            AgentPlanGroup(id: 1, kind: .moves(toLabel: "Images", isNew: true), steps: [0, 3]),
            AgentPlanGroup(id: 2, kind: .moves(toLabel: "2026", isNew: true), steps: [1, 2]),
            AgentPlanGroup(id: 3, kind: .copies(toLabel: "Documents", isNew: false), steps: [4]),
            AgentPlanGroup(id: 4, kind: .renames, steps: [5, 6, 7]),
            AgentPlanGroup(id: 5, kind: .trash, steps: [8], guardedBy: .trash),
            AgentPlanGroup(id: 6, kind: .moves(toLabel: "Documents", isNew: false), steps: [10]),
            AgentPlanGroup(id: 7, kind: .copies(toLabel: "Images", isNew: true), steps: [11])
        ]
        return AgentChangePlan(title: .organize(rootLabel: "Downloads"), steps: steps, groups: groups, notices: [], leftOut: [:])
    }()

    private var rootURL: URL { URL(fileURLWithPath: root, isDirectory: true) }
    private var docsURL: URL { URL(fileURLWithPath: "/home/helm/Documents", isDirectory: true) }

    func testEveryGroupTickedRunsInOrder() {
        let commands = AgentPlanCompiler.commands(for: plan, ticked: Set(0...7))
        XCTAssertEqual(commands, [
            .createFolder(key: "n1", parent: .url(rootURL), name: name("Images")),
            .createFolder(key: "n2", parent: .key("n1"), name: name("2026")),
            .createFolder(key: "n3", parent: .url(rootURL), name: name("Unused")),
            .batchRename([AgentCompiledRename(source: source(d), name: name("e.txt")),
                          AgentCompiledRename(source: source(h), name: name("i.txt"))]),
            .batchRename([AgentCompiledRename(source: source(f), name: name("g.txt"))]),
            .move(sources: [source(a)], to: .key("n2")),
            .move(sources: [source(b)], to: .key("n1")),
            .move(sources: [source(j)], to: .url(docsURL)),
            .copy(sources: [source(c)], to: .url(docsURL)),
            .copy(sources: [source(k)], to: .key("n1")),
            .trash([source(old)])
        ])
        XCTAssertEqual(commands.filter { if case .createFolder = $0 { return true }; return false }.count,
                       plan.counts(ticked: Set(0...7)).newFolders, "the folders made are the folders the counts line counts")
    }

    func testUntickedGroupsCompileToNothing() {
        XCTAssertEqual(AgentPlanCompiler.commands(for: plan, ticked: []), [])
        // The default ticks leave the guarded Trash group out.
        let commands = AgentPlanCompiler.commands(for: plan, ticked: plan.defaultTicked)
        XCTAssertFalse(commands.contains { if case .trash = $0 { return true }; return false }, "an unticked Trash group runs nothing")
        XCTAssertEqual(commands.count, 10)
        // Only the renames.
        XCTAssertEqual(AgentPlanCompiler.commands(for: plan, ticked: [4]).count, 2)
        // Only the copy to Documents: no new folder, no move, no rename.
        XCTAssertEqual(AgentPlanCompiler.commands(for: plan, ticked: [3]), [.copy(sources: [source(c)], to: .url(docsURL))])
    }

    func testANewFolderIsMadeOnlyWhenATickedStepNeedsItAndItsParentComesFirst() {
        // The move into 2026 needs 2026, and 2026 needs Images, which nothing else of the ticked groups uses.
        XCTAssertEqual(AgentPlanCompiler.commands(for: plan, ticked: [2]), [
            .createFolder(key: "n1", parent: .url(rootURL), name: name("Images")),
            .createFolder(key: "n2", parent: .key("n1"), name: name("2026")),
            .move(sources: [source(a)], to: .key("n2"))
        ])
        XCTAssertEqual(plan.counts(ticked: [2]).newFolders, 2)
        // A group of new folders on its own makes its folders and nothing else.
        XCTAssertEqual(AgentPlanCompiler.commands(for: plan, ticked: [0]),
                       [.createFolder(key: "n3", parent: .url(rootURL), name: name("Unused"))])
        // The copy into Images needs Images and not 2026.
        XCTAssertEqual(AgentPlanCompiler.commands(for: plan, ticked: [7]), [
            .createFolder(key: "n1", parent: .url(rootURL), name: name("Images")),
            .copy(sources: [source(k)], to: .key("n1"))
        ])
    }

    func testAParentDeclaredAfterItsChildIsStillMadeFirst() {
        let x = item(root + "/x.txt", handle: "f20")
        let steps: [AgentPlanStep] = [
            .newFolder(key: "n2", parent: .new(key: "n1"), name: name("Inner")),
            .newFolder(key: "n1", parent: .existing(rootItem), name: name("Outer")),
            .move(x, to: .new(key: "n2"))
        ]
        let reversed = AgentChangePlan(title: .move(1), steps: steps,
                                       groups: [AgentPlanGroup(id: 0, kind: .moves(toLabel: "Inner", isNew: true), steps: [0, 1, 2])],
                                       notices: [], leftOut: [:])
        XCTAssertEqual(AgentPlanCompiler.commands(for: reversed, ticked: [0]), [
            .createFolder(key: "n1", parent: .url(rootURL), name: name("Outer")),
            .createFolder(key: "n2", parent: .key("n1"), name: name("Inner")),
            .move(sources: [source(x)], to: .key("n2"))
        ])
    }

    func testEverySourceCarriesThePlanItemsIdentityAndKind() {
        let commands = AgentPlanCompiler.commands(for: plan, ticked: Set(0...7))
        var sources: [AgentCompiledSource] = []
        for command in commands {
            switch command {
            case .createFolder, .createFile: break
            case .batchRename(let renames): sources += renames.map(\.source)
            case .move(let items, _), .copy(let items, _), .trash(let items): sources += items
            }
        }
        let items = [a, b, c, d, f, h, old, j, k]
        XCTAssertEqual(sources.count, items.count)
        for planned in items {
            let compiled = sources.first { $0.url.path == planned.path }
            XCTAssertEqual(compiled?.identity, planned.identity, planned.name)
            XCTAssertEqual(compiled?.kind, planned.kind, planned.name)
        }
        XCTAssertTrue(sources.first { $0.url.path == j.path }?.url.hasDirectoryPath == true, "a folder's address is a folder's")
    }

    func testAnIDThatIsNoGroupOfThePlanCompilesToNothing() {
        XCTAssertEqual(AgentPlanCompiler.commands(for: plan, ticked: [42]), [])
    }

    // MARK: New files

    /// A new folder, two new files in it and one beside it, and a move into the new folder.
    private lazy var creation: AgentChangePlan = {
        let steps: [AgentPlanStep] = [
            .newFolder(key: "n1", parent: .existing(rootItem), name: name("Trip")),                       // 0
            .newFile(parent: .new(key: "n1"), name: name("Packing List.txt"), text: "Passport\nCharger"),  // 1
            .newFile(parent: .new(key: "n1"), name: name("Budget.csv"), text: "Item,Cost\r\nTrain,40"),   // 2
            .newFile(parent: .existing(rootItem), name: name("Read Me.md"), text: "# Trip\n\n- one 🎒"),   // 3
            .move(a, to: .new(key: "n1"))                                                                 // 4
        ]
        let groups = [
            AgentPlanGroup(id: 1, kind: .newFiles(toLabel: "Trip", isNew: true), steps: [0, 1, 2]),
            AgentPlanGroup(id: 2, kind: .newFiles(toLabel: "Downloads", isNew: false), steps: [3]),
            AgentPlanGroup(id: 3, kind: .moves(toLabel: "Trip", isNew: true), steps: [4])
        ]
        return AgentChangePlan(title: .organize(rootLabel: "Downloads"), steps: steps, groups: groups, notices: [], leftOut: [:])
    }()

    func testANewFileIsMadeAfterTheFolderItGoesInWithItsTextInUTF8() {
        XCTAssertEqual(AgentPlanCompiler.commands(for: creation, ticked: [1, 2, 3]), [
            .createFolder(key: "n1", parent: .url(rootURL), name: name("Trip")),
            .createFile(parent: .key("n1"), name: name("Packing List.txt"), contents: Data("Passport\nCharger".utf8)),
            .createFile(parent: .key("n1"), name: name("Budget.csv"), contents: Data("Item,Cost\r\nTrain,40".utf8)),
            .createFile(parent: .url(rootURL), name: name("Read Me.md"), contents: Data("# Trip\n\n- one 🎒".utf8)),
            .move(sources: [source(a)], to: .key("n1"))
        ])
        // A file beside the folder needs no folder; the move alone still makes it.
        XCTAssertEqual(AgentPlanCompiler.commands(for: creation, ticked: [2]),
                       [.createFile(parent: .url(rootURL), name: name("Read Me.md"), contents: Data("# Trip\n\n- one 🎒".utf8))])
        XCTAssertEqual(AgentPlanCompiler.commands(for: creation, ticked: [3]), [
            .createFolder(key: "n1", parent: .url(rootURL), name: name("Trip")),
            .move(sources: [source(a)], to: .key("n1"))
        ])
        XCTAssertEqual(creation.counts(ticked: [1]), AgentPlanCounts(newFiles: 2, newFolders: 1))
    }

    func testRTFAndWordAreMadeFromTheTextAParagraphALine() throws {
        let text = "Dear Sam,\nThe trip is on.\r\n{Braces} and \\backslashes stay text.\n\nSee you"
        let wanted = "Dear Sam,\nThe trip is on.\n{Braces} and \\backslashes stay text.\n\nSee you"
        let plan = AgentChangePlan(title: .create(2), steps: [
            .newFile(parent: .existing(rootItem), name: name("Letter.rtf"), text: text),
            .newFile(parent: .existing(rootItem), name: name("Letter.DOCX"), text: text)
        ], groups: [AgentPlanGroup(id: 1, kind: .newFiles(toLabel: "Downloads", isNew: false), steps: [0, 1])],
           notices: [], leftOut: [:])
        let commands = AgentPlanCompiler.commands(for: plan, ticked: [1])
        XCTAssertEqual(commands.count, 2)
        guard case .createFile(_, _, let rtf?) = commands[0], case .createFile(_, _, let docx?) = commands[1] else {
            return XCTFail("no bytes: \(commands)")
        }
        XCTAssertTrue(String(decoding: rtf.prefix(5), as: UTF8.self) == "{\\rtf", "an RTF file")
        let readRTF = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                             documentAttributes: nil)
        XCTAssertEqual(readRTF.string, wanted)
        XCTAssertEqual(Array(docx.prefix(2)), Array("PK".utf8), "a Word file is a zip file")
        let readWord = try NSAttributedString(data: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                              documentAttributes: nil)
        XCTAssertEqual(readWord.string.trimmingCharacters(in: .newlines), wanted)
        XCTAssertEqual(readWord.string.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 4, "a paragraph a line")
    }

    func testEveryOtherKindIsItsTextAsWritten() {
        for file in ["a.json", "b.html", "c.swift", "d.tsv", "e.txt"] {
            XCTAssertEqual(AgentNewFileContents.data(name: name(file), text: "<b>{\"x\": 1}</b>\r\n"),
                           Data("<b>{\"x\": 1}</b>\r\n".utf8), file)
        }
        XCTAssertEqual(AgentNewFileContents.data(name: name("empty.md"), text: ""), Data())
    }
}
#endif
