import XCTest
@testable import HelmCore

/// The AI search's kind row: the kinds it offers, each one in the kind table, and how a chosen kind holds every
/// query a model plans to it, so no answer widens the search to another kind.
final class AISearchKindChoiceTests: XCTestCase {
    func testTheRowOffersSevenKindsAfterAny() {
        XCTAssertEqual(AISearchKind.searchChoices, [.image, .video, .document, .folder, .code, .audio, .archive])
        XCTAssertEqual(Set(AISearchKind.searchChoices).count, AISearchKind.searchChoices.count)
    }

    /// Every file kind the row offers is in the table both ways: by extension and by type identifier, and Spotlight is
    /// asked for it. A folder is decided by what the item is.
    func testEveryKindTheRowOffersIsInTheTable() {
        let samples: [AISearchKind: (extensions: [String], identifiers: [String])] = [
            .image: (["jpg", "heic", "png"], ["public.jpeg", "public.heic"]),
            .video: (["mov", "mp4"], ["com.apple.quicktime-movie", "public.mpeg-4"]),
            .document: (["docx", "pages"], ["com.microsoft.word.doc", "com.apple.iwork.pages.pages"]),
            .code: (["swift", "py"], ["public.swift-source", "public.python-script"]),
            .audio: (["mp3", "m4a", "wav", "flac", "aiff"], ["public.mp3", "com.apple.m4a-audio", "public.aiff-audio"]),
            .archive: (["zip", "tar", "gz", "7z", "rar", "dmg", "iso"], ["public.zip-archive", "org.7-zip.7-zip-archive",
                                                                          "com.apple.disk-image-udif"])
        ]
        for kind in AISearchKind.searchChoices where kind != .folder {
            let sample = try? XCTUnwrap(samples[kind], kind.rawValue)
            XCTAssertFalse(kind.typeIdentifiers.isEmpty, kind.rawValue)
            XCTAssertTrue(AISearchKind.extensions.contains { $0.kind == kind && !$0.extensions.isEmpty }, kind.rawValue)
            XCTAssertTrue(AISearchKind.identifiers.contains { $0.kind == kind && !$0.identifiers.isEmpty }, kind.rawValue)
            for ext in sample?.extensions ?? [] {
                XCTAssertEqual(AISearchKind.of(typeIdentifier: nil, extension: ext, kind: .regular), kind, ext)
            }
            for identifier in sample?.identifiers ?? [] {
                XCTAssertEqual(AISearchKind.of(typeIdentifier: identifier, extension: "", kind: .regular), kind, identifier)
            }
        }
        XCTAssertEqual(AISearchKind.audio.typeIdentifiers, ["public.audio"])
        XCTAssertEqual(AISearchKind.archive.typeIdentifiers, ["public.archive", "public.disk-image"])
        XCTAssertEqual(AISearchKind.of(typeIdentifier: nil, extension: "", kind: .directory), .folder)
    }

    /// Photo is pictures alone; Document takes in PDF, text, spreadsheets and presentations, and nothing else does.
    func testWhatEachChoiceTakesIn() {
        XCTAssertEqual(AISearchKind.allCases.filter { AISearchKind.image.covers($0) }, [.image])
        XCTAssertEqual(Set(AISearchKind.allCases.filter { AISearchKind.document.covers($0) }),
                       [.document, .pdf, .text, .spreadsheet, .presentation])
        for kind in AISearchKind.searchChoices where kind != .document {
            XCTAssertEqual(AISearchKind.allCases.filter { kind.covers($0) }, [kind], kind.rawValue)
        }
    }

    // MARK: The plan clamp

    func testAQueryWithNoKindIsGivenTheChosenOne() {
        let query = AISearchQuery(nameAny: ["beach"]).limited(to: .image)
        XCTAssertEqual(query.kinds, [.image])
        XCTAssertEqual(query.nameAny, ["beach"], "the rest is left as it is")
    }

    func testAnotherKindCanNotWidenIt() {
        XCTAssertEqual(AISearchQuery(nameAny: ["beach"], kinds: [.video]).limited(to: .image).kinds, [.image])
        XCTAssertEqual(AISearchQuery(kinds: [.video, .audio, .document]).limited(to: .image).kinds, [.image])
        XCTAssertEqual(AISearchQuery(kinds: [.document]).limited(to: .pdf).kinds, [.pdf], "a wider kind is cut to the chosen one")
        XCTAssertEqual(AISearchQuery(kinds: [.folder]).limited(to: .archive).kinds, [.archive])
    }

    func testANarrowerKindTheChosenOneCoversStays() {
        XCTAssertEqual(AISearchQuery(kinds: [.pdf]).limited(to: .document).kinds, [.pdf])
        XCTAssertEqual(AISearchQuery(kinds: [.pdf, .image, .spreadsheet]).limited(to: .document).kinds, [.pdf, .spreadsheet])
        XCTAssertEqual(AISearchQuery(kinds: [.image, .video]).limited(to: .image).kinds, [.image])
    }

    func testAnExtensionStaysOnlyWhenItIsOfTheChosenKind() {
        let query = AISearchQuery(extensions: ["jpg", "pdf", "heic", "xyz123", "mov"])
        XCTAssertEqual(query.limited(to: .image).extensions, ["jpg", "heic"])
        XCTAssertEqual(query.limited(to: .document).extensions, ["pdf"])
        XCTAssertEqual(query.limited(to: .video).extensions, ["mov"])
        XCTAssertEqual(query.limited(to: .folder).extensions, [], "a folder has no extension to look for")
        XCTAssertEqual(AISearchQuery(extensions: ["txt", "csv", "key"]).limited(to: .document).extensions, ["txt", "csv", "key"])
    }

    func testEveryOtherFieldIsLeftAsItIs() {
        let day = Date(timeIntervalSince1970: 1_780_000_000)
        let query = AISearchQuery(nameAll: ["a"], nameAny: ["b"], contentAll: ["c"], folderAny: ["d"], kinds: [.audio],
                                  dateField: .modified, dateFrom: day, dateTo: day.addingTimeInterval(86_400),
                                  sizeMinBytes: 10, sizeMaxBytes: 20)
        var expected = query
        expected.kinds = [.image]
        XCTAssertEqual(query.limited(to: .image), expected)
        XCTAssertEqual(query.limited(to: .audio), query, "a query already of the chosen kind is unchanged")
    }

    func testThePlanKeepsItsOrderAndQueriesThatBecomeTheSameAreOne() {
        let photos = AISearchQuery(nameAny: ["beach"], kinds: [.image])
        let videos = AISearchQuery(nameAny: ["beach"], kinds: [.video])
        let anything = AISearchQuery(nameAny: ["beach"])
        let wider = AISearchQuery(nameAny: ["sea"], kinds: [.document])
        let plan = AISearchPlan(sort: .newest, queries: [photos, videos, anything, wider]).limited(to: .image)
        XCTAssertEqual(plan.sort, .newest)
        XCTAssertEqual(plan.queries, [photos, AISearchQuery(nameAny: ["sea"], kinds: [.image])])
        XCTAssertTrue(plan.queries.allSatisfy { $0.kinds.allSatisfy { AISearchKind.image.covers($0) } })
    }

    func testASearchHasNoKindUntilOneIsChosen() {
        let home = URL(fileURLWithPath: "/home/helm", isDirectory: true)
        let plain = SearchQuery(text: "beach", scope: .home, bookmarkPaths: [], homeDirectory: home, lastDirectory: nil,
                                showHidden: false, limit: 100)
        XCTAssertNil(plain.kind)
        var chosen = plain
        chosen.kind = .image
        XCTAssertNotEqual(plain, chosen, "the kind is part of what a search is")
        XCTAssertEqual(SearchQuery(text: "beach", scope: .home, bookmarkPaths: [], homeDirectory: home, lastDirectory: nil,
                                   showHidden: false, limit: 100, usesAI: true, kind: .image).kind, .image)
    }
}
