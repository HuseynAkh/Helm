import XCTest
import HelmCore
@testable import HelmSearch

/// One planned query against one item: each field on its own, the scope, and what only the index can vouch for.
final class AISearchMatcherTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/home/helm/Downloads", isDirectory: true)
    private let march = Date(timeIntervalSince1970: 1_773_500_000)   // 14 March 2026
    private let july = Date(timeIntervalSince1970: 1_783_000_000)    // early July 2026

    private func file(_ path: String, kind: FileEntryKind = .regular, size: Int64 = 1000, modified: Date? = nil,
                      created: Date = .distantPast, type: String? = nil) -> FileEntry {
        FileEntry(url: root.appendingPathComponent(path), kind: kind, size: size, modificationDate: modified ?? march,
                  creationDate: created, contentTypeIdentifier: type)
    }

    private func matches(_ entry: FileEntry, _ query: AISearchQuery, verified: Bool = false, scope: URL? = nil) -> Bool {
        AISearchMatcher.matches(entry, query, scopeRoot: scope ?? root, contentVerified: verified)
    }

    func testNameWordsAllAndAny() {
        let entry = file("Plumber Invoice Café.pdf")
        XCTAssertTrue(matches(entry, AISearchQuery(nameAll: ["invoice", "PLUMBER"])))
        XCTAssertFalse(matches(entry, AISearchQuery(nameAll: ["invoice", "receipt"])), "every name_all word")
        XCTAssertTrue(matches(entry, AISearchQuery(nameAny: ["receipt", "invoice"])))
        XCTAssertFalse(matches(entry, AISearchQuery(nameAny: ["receipt", "bill"])))
        XCTAssertTrue(matches(entry, AISearchQuery(nameAny: ["cafe"])), "accents don't count")
    }

    func testContentWordsNeedTheIndex() {
        let entry = file("Scan_0042.pdf")
        let query = AISearchQuery(contentAll: ["plumber"])
        XCTAssertFalse(matches(entry, query, verified: false), "a walk can't see inside files")
        XCTAssertTrue(matches(entry, query, verified: true), "the index already checked the words")
    }

    func testKindsThroughTheOneTable() {
        XCTAssertTrue(matches(file("a.pdf"), AISearchQuery(kinds: [.pdf])))
        XCTAssertTrue(matches(file("a.pdf"), AISearchQuery(kinds: [.document])), "document covers pdf")
        XCTAssertFalse(matches(file("a.png"), AISearchQuery(kinds: [.document])))
        XCTAssertTrue(matches(file("photo", type: "public.jpeg"), AISearchQuery(kinds: [.image])), "the type settles an unknown extension")
        XCTAssertTrue(matches(file("Receipts", kind: .directory), AISearchQuery(kinds: [.folder])))
        XCTAssertFalse(matches(file("link", kind: .symlinkToFile), AISearchQuery(kinds: [.pdf])))
        XCTAssertEqual(AISearchMatcher.kind(of: file("deck.key")), .presentation)
    }

    func testExtensions() {
        XCTAssertTrue(matches(file("Report.DOCX"), AISearchQuery(extensions: ["docx"])))
        XCTAssertFalse(matches(file("Report.doc"), AISearchQuery(extensions: ["docx"])))
        XCTAssertFalse(matches(file("README"), AISearchQuery(extensions: ["docx"])))
    }

    func testFolderWordsAreLookedForBetweenTheScopeAndTheItem() {
        let entry = file("Receipts/2026/scan.pdf")
        XCTAssertTrue(matches(entry, AISearchQuery(folderAny: ["receipt"])))
        XCTAssertTrue(matches(entry, AISearchQuery(folderAny: ["nothing", "2026"])))
        XCTAssertFalse(matches(entry, AISearchQuery(folderAny: ["downloads"])), "the folder searched isn't a folder above it")
        XCTAssertFalse(matches(entry, AISearchQuery(folderAny: ["scan"])), "the item's own name isn't a folder")
    }

    func testDatesByField() {
        let spring = AISearchQuery(dateField: .modified, dateFrom: march.addingTimeInterval(-86_400),
                                   dateTo: march.addingTimeInterval(86_400))
        XCTAssertTrue(matches(file("a.txt", modified: march), spring))
        XCTAssertFalse(matches(file("a.txt", modified: july), spring))
        var created = spring; created.dateField = .created
        XCTAssertFalse(matches(file("a.txt", modified: march), created), "no creation date known")
        XCTAssertTrue(matches(file("a.txt", modified: july, created: march), created))
        var any = spring; any.dateField = .any
        XCTAssertTrue(matches(file("a.txt", modified: july, created: march), any))
        XCTAssertFalse(matches(file("a.txt", modified: july), any), "nothing Helm can read is in range")
        XCTAssertTrue(matches(file("a.txt", modified: july), any, verified: true), "the index read the dates Helm can't")
        var added = spring; added.dateField = .added
        XCTAssertFalse(matches(file("a.txt"), added), "Helm doesn't know when a file was added")
        XCTAssertTrue(matches(file("a.txt"), added, verified: true))
        var opened = spring; opened.dateField = .opened
        var recent = file("a.txt"); recent.lastOpenedDate = march
        XCTAssertTrue(matches(recent, opened))
        recent.lastOpenedDate = july
        XCTAssertFalse(matches(recent, opened))
        let both = AISearchQuery(dateField: .modified, dateFrom: march, dateTo: march)
        XCTAssertTrue(matches(file("a.txt", modified: march), both), "both ends are included")
    }

    func testSizes() {
        XCTAssertTrue(matches(file("big.mov", size: 5_000_000), AISearchQuery(sizeMinBytes: 1_000_000)))
        XCTAssertFalse(matches(file("small.mov", size: 500), AISearchQuery(sizeMinBytes: 1_000_000)))
        XCTAssertTrue(matches(file("small.mov", size: 500), AISearchQuery(sizeMaxBytes: 1_000)))
        XCTAssertFalse(matches(file("big.mov", size: 5_000), AISearchQuery(sizeMaxBytes: 1_000)))
        XCTAssertFalse(matches(file("Folder", kind: .directory, size: 0), AISearchQuery(sizeMaxBytes: 1_000)),
                       "a folder's size isn't known")
    }

    func testTheItemMustBeInsideTheScope() {
        let outside = FileEntry(url: URL(fileURLWithPath: "/home/helm/Documents/invoice.pdf"))
        XCTAssertFalse(AISearchMatcher.matches(outside, AISearchQuery(nameAny: ["invoice"]), scopeRoot: root, contentVerified: true))
        let lookalike = FileEntry(url: URL(fileURLWithPath: "/home/helm/Downloads2/invoice.pdf"))
        XCTAssertFalse(AISearchMatcher.matches(lookalike, AISearchQuery(nameAny: ["invoice"]), scopeRoot: root, contentVerified: true),
                       "compared part by part, not by a prefix of text")
        XCTAssertFalse(AISearchMatcher.matches(FileEntry(url: root), AISearchQuery(), scopeRoot: root, contentVerified: true),
                       "the folder searched isn't one of its results")
        XCTAssertTrue(AISearchMatcher.matches(outside, AISearchQuery(nameAny: ["invoice"]), scopeRoot: nil, contentVerified: false),
                      "a search of the whole Mac has no folder to stay in")
    }

    func testEveryFieldMustHold() {
        let query = AISearchQuery(nameAny: ["invoice"], kinds: [.pdf], sizeMaxBytes: 10_000)
        XCTAssertTrue(matches(file("invoice.pdf", size: 900), query))
        XCTAssertFalse(matches(file("invoice.png", size: 900), query))
        XCTAssertFalse(matches(file("invoice.pdf", size: 90_000), query))
        XCTAssertFalse(matches(file("receipt.pdf", size: 900), query))
    }

    // MARK: The kind row's filter

    /// The filter every search runs while a kind is chosen: Photo is pictures, Document takes in PDF, text,
    /// spreadsheets and presentations, Folder is folders, and an item the table has no word for is of no kind.
    func testTheKindRowsFilter() {
        let cases: [(AISearchKind, admitted: [FileEntry], refused: [FileEntry])] = [
            (.image, [file("beach.jpg"), file("IMG_0001.HEIC"), file("scan", type: "public.png")],
             [file("beach.pdf"), file("beach.mov"), file("Beach", kind: .directory), file("beach.psd.zip")]),
            (.video, [file("clip.mov"), file("clip.mp4")], [file("clip.jpg"), file("clip.mp3")]),
            (.document, [file("a.pdf"), file("a.txt"), file("a.xlsx"), file("a.key"), file("a.docx"), file("a.md")],
             [file("a.png"), file("a.swift"), file("a.zip"), file("Docs", kind: .directory)]),
            (.folder, [file("Holiday", kind: .directory)], [file("Holiday.zip"), file("Helm.app", kind: .package), file("a.txt")]),
            (.code, [file("main.swift"), file("tool.py"), file("page.html")], [file("notes.txt"), file("data.json")]),
            (.audio, [file("song.mp3"), file("memo.m4a"), file("take.wav")], [file("song.mp4"), file("song.txt")]),
            (.archive, [file("backup.zip"), file("disk.dmg"), file("logs.tar.gz")], [file("backup.txt"), file("Backup", kind: .directory)])
        ]
        for (kind, admitted, refused) in cases {
            for entry in admitted { XCTAssertTrue(AISearchMatcher.isOf(kind, entry), "\(kind.rawValue): \(entry.name)") }
            for entry in refused { XCTAssertFalse(AISearchMatcher.isOf(kind, entry), "\(kind.rawValue): \(entry.name)") }
        }
        for kind in AISearchKind.searchChoices {
            XCTAssertFalse(AISearchMatcher.isOf(kind, file("link", kind: .symlinkToFile)), "a link is of no kind")
            XCTAssertFalse(AISearchMatcher.isOf(kind, file("unknown.xyz123")), "nor is a file the table doesn't know")
        }
    }

    /// A planned query kept to a chosen kind matches nothing of another kind, whatever its words.
    func testAQueryKeptToAKindMatchesThatKindAlone() {
        let query = AISearchQuery(nameAny: ["beach"], kinds: [.video], extensions: ["pdf"]).limited(to: .image)
        XCTAssertTrue(matches(file("beach.jpg"), query))
        XCTAssertFalse(matches(file("beach.mov"), query))
        XCTAssertFalse(matches(file("beach.pdf"), query))
        XCTAssertFalse(matches(file("sunset.jpg"), query), "the words still count")
    }
}
