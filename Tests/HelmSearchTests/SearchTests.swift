// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
import HelmFileSystem
@testable import HelmSearch

final class SearchTests: XCTestCase {
    private struct Clock: HelmClock { func now() -> Date { Date(timeIntervalSince1970: 10_000_000) } }
    private func context(_ text: String = "report", limit: Int = 300) -> SearchRankingContext {
        SearchRankingContext(query: SearchQuery(text: text, scope: .userFolders, bookmarkPaths: [], homeDirectory: URL(fileURLWithPath: "/Home/User"), lastDirectory: nil, showHidden: false, limit: limit))
    }
    private func candidate(_ path: String, date: Date = .distantPast, kind: FileEntryKind = .regular, hidden: Bool = false) -> SearchCandidate {
        SearchCandidate(entry: FileEntry(url: URL(fileURLWithPath: path), kind: kind, isHidden: hidden, modificationDate: date))
    }
    func testNameClassificationAndFrozenWeights() {
        let cases: [(String, SearchRanker.NameMatch, Int)] = [("report", .exact, 1300), ("reporting", .prefix, 900), ("my-report", .wordBoundary, 600), ("xreport", .substring, 600), ("other", .none, 0)]
        for (name, match, score) in cases {
            XCTAssertEqual(SearchRanker.nameMatch(name, query: "report"), match)
            XCTAssertEqual(SearchRanker.score(candidate("/else/" + name), context: context(), now: Clock().now()), score)
        }
        XCTAssertEqual(SearchRanker.nameMatch("report", query: ""), .none)
    }
    func testRankAndDeterministicTies() {
        let values = [candidate("/z/report"), candidate("/b/reporting"), candidate("/a/report")]
        let batch = SearchRanker.rank(values, context: context(), clock: Clock())
        XCTAssertEqual(batch.results.map(\.entry.url.path), ["/a/report", "/z/report", "/b/reporting"])
        XCTAssertEqual(batch.results.map(\.rank), [0, 1, 2]); XCTAssertFalse(batch.truncated)
        XCTAssertEqual(SearchRanker.rank(values.reversed(), context: context(), clock: Clock()).results, batch.results)
    }
    func testBonusesAndPenalties() {
        let base = SearchRanker.score(candidate("/else/report"), context: context(), now: Clock().now())
        XCTAssertEqual(SearchRanker.score(candidate("/Home/User/Documents/report"), context: context(), now: Clock().now()) - base, 500)
        XCTAssertEqual(SearchRanker.score(candidate("/System/report"), context: context(), now: Clock().now()) - base, -650)
        XCTAssertEqual(SearchRanker.score(candidate("/else/report", hidden: true), context: context(), now: Clock().now()) - base, -280)
        XCTAssertEqual(SearchRanker.score(candidate("/else/report", date: Clock().now(), kind: .directory), context: context(), now: Clock().now()) - base, 170)
        XCTAssertTrue(SearchRanker.documentLike(candidate("/a/test.pdf")))
        XCTAssertEqual(context().preferredRoots.first?.path, "/Home/User/Documents")
    }
    func testCapsExposeOlderExactMatchAndDeduplicate() {
        var values = (0..<450).map { candidate("/a/report\($0)", date: Clock().now()) }
        values.append(candidate("/a/report"))
        let batch = SearchRanker.rank(values, context: context(limit: 1), clock: Clock())
        XCTAssertTrue(batch.truncated); XCTAssertTrue(batch.candidateLimitReached); XCTAssertEqual(batch.consideredCount, 450)
        XCTAssertNotEqual(batch.results.first?.entry.name, "report")
        XCTAssertEqual(SearchRanker.hardCap(limit: 300), 900); XCTAssertEqual(SearchRanker.hardCap(limit: Int.max), Int.max)
        XCTAssertEqual(SearchRanker.rank([values[0], values[0]], context: context(), clock: Clock()).results.count, 1)
        XCTAssertTrue(SearchRanker.rank([values[0]], context: context(limit: -1), clock: Clock()).results.isEmpty)
    }
    func testParserGrammarAndLiteralInjection() throws {
        XCTAssertEqual(try SearchQueryParser.tokenize(#"one "two three" four\ five"#), ["one", "two three", "four five"])
        let spec = try SearchQueryParser.compile(SearchRequest(text: #""Quarter Report" kind:regular ext:pdf after:2026-01-01 before:2027-01-01 size:>5 size:<100"#, filters: [.tag("Work Stuff")]))
        XCTAssertEqual(spec.clauses.count, 8); XCTAssertTrue(spec.requiresTags)
        let entry = FileEntry(url: URL(fileURLWithPath: "/Quarter Report.pdf"), size: 10, modificationDate: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertTrue(spec.matches(entry, tags: ["Work Stuff"])); XCTAssertFalse(spec.matches(entry))
        for literal in ["*", "?", "$name", "TRUEPREDICATE", "x:OR", "[cd]", "'OR'", "a\\\"b"] {
            let parsed = try SearchQueryParser.compile(SearchRequest(text: literal))
            XCTAssertEqual(parsed.clauses.count, 1)
            XCTAssertFalse(parsed.matches(FileEntry(url: URL(fileURLWithPath: "/unrelated"))))
        }
        let day = try SearchQueryParser.compile(SearchRequest(text: "modified:2026-01-01"))
        XCTAssertEqual(day.clauses.count, 2)
    }
    func testParserFailuresAndHidden() throws {
        for text in ["\"open", "tail\\", "kind:nope", "ext:", "tag:", "before:2026-02-30", "size:>-1", "size:>99999999999999999999999", String(repeating: "x", count: 4097), Array(repeating: "x", count: 129).joined(separator: " ")] {
            XCTAssertThrowsError(try SearchQueryParser.compile(SearchRequest(text: text)), text)
        }
        XCTAssertFalse(try SearchQueryParser.compile(SearchRequest(text: "")).matches(FileEntry(url: URL(fileURLWithPath: "/.hidden"))))
    }
    func testSavedSearchCodecs() throws {
        let document = SavedSearchDocument(name: "Reports", request: SearchRequest(text: "ext:pdf", scope: .thisMac))
        XCTAssertEqual(try SavedSearchCodec.decode(SavedSearchCodec.encode(document)), document)
        XCTAssertThrowsError(try SavedSearchCodec.encode(SavedSearchDocument(name: "Future", request: document.request, version: 2)))
        XCTAssertThrowsError(try SavedSearchCodec.decode(Data("{}".utf8)))
        let finder = try FinderSavedSearchDocument(rawQuery: "opaque == 'value'", searchScopes: ["/Home/User"])
        XCTAssertEqual(try FinderSavedSearchCodec.decode(FinderSavedSearchCodec.encode(finder)).rawQuery, finder.rawQuery)
        XCTAssertFalse(try FinderSavedSearchCodec.decode(FinderSavedSearchCodec.encode(finder)).isReadOnly)
        XCTAssertEqual(try FinderSavedSearchCodec.replacing(finder, rawQuery: "new", searchScopes: ["/tmp"]).rawQuery, "new")
        let data = try PropertyListSerialization.data(fromPropertyList: ["RawQuery": "x", "SearchCriteria": ["FXScopeArrayOfPaths": ["/tmp"], "Unknown": [1, 2]], "Future": Data([1, 2])], format: .binary, options: 0)
        let imported = try FinderSavedSearchCodec.decode(data)
        XCTAssertTrue(imported.isReadOnly); XCTAssertEqual(FinderSavedSearchCodec.encode(imported), data)
        XCTAssertThrowsError(try FinderSavedSearchCodec.replacing(imported, rawQuery: "new", searchScopes: []))
        XCTAssertThrowsError(try FinderSavedSearchCodec.decode(Data("bad".utf8)))
    }
    func testFallbackWalkingLimitsHiddenAndCancellation() async throws {
        let fs = InMemoryFileSystem(); let root = URL(fileURLWithPath: "/root")
        try await fs.createDirectory(at: root)
        try await fs.createDirectory(at: root.appendingPathComponent("sub"))
        for path in ["report", ".report", "sub/report"] { try await fs.createFileExclusively(at: root.appendingPathComponent(path), contents: Data()) }
        try await fs.createSymbolicLink(at: root.appendingPathComponent("loop"), destination: root)
        let service = EnumerationSearchService(fileSystem: fs, clock: Clock())
        let spec = try SearchQueryParser.compile(SearchRequest(text: "report", scope: .currentFolder(root)))
        let batch = try await service.search(spec, roots: [], context: context())
        XCTAssertEqual(batch.results.count, 2); XCTAssertFalse(batch.truncated)
        let bounded = try await service.search(spec, roots: [], context: context(), visitLimit: 1)
        XCTAssertTrue(bounded.truncated)
        let shallow = try await service.search(spec, roots: [], context: context(), maxDepth: 0)
        XCTAssertTrue(shallow.truncated); XCTAssertEqual(shallow.results.count, 1)
        let hidden = try SearchQueryParser.compile(SearchRequest(text: "report", scope: .currentFolder(root), includeHidden: true))
        let all = try await service.search(hidden, roots: [], context: context())
        XCTAssertEqual(all.results.count, 3)
        await fs.setLatency(nanoseconds: 1_000_000_000)
        let task = Task { try await service.search(spec, roots: [], context: context()) }; task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(SearchFallbackPolicy.shouldEnumerate(spotlightAvailable: true, knownUnindexed: false, userRequested: false))
        XCTAssertTrue(SearchFallbackPolicy.shouldEnumerate(spotlightAvailable: false, knownUnindexed: false, userRequested: false))
    }
    func testRankingContextAndAgeBoundaries() {
        let home = URL(fileURLWithPath: "/Home/User")
        let query = SearchQuery(text: "report", scope: .currentFolder(home), bookmarkPaths: [home.path], homeDirectory: home, lastDirectory: home, showHidden: true, limit: 5)
        let ctx = SearchRankingContext(query: query, preferredRoots: [])
        let baseline = SearchRanker.score(candidate("/else/report"), context: context(), now: Clock().now())
        XCTAssertEqual(SearchRanker.score(candidate("/Home/User/report"), context: ctx, now: Clock().now()) - baseline, 760)
        for (age, bonus) in [(86400.0, 55), (604800.0, 25), (2592000.0, 0)] {
            XCTAssertEqual(SearchRanker.score(candidate("/else/report", date: Clock().now().addingTimeInterval(-age)), context: context(), now: Clock().now()) - baseline, bonus)
        }
        XCTAssertEqual(SearchRanker.score(candidate("/Home/User/Library/report"), context: context(), now: Clock().now()), baseline)
        XCTAssertEqual(SearchRanker.score(candidate("/Home/Username/report"), context: context(), now: Clock().now()), baseline)
        XCTAssertEqual(SearchRanker.score(candidate("/System/report"), context: SearchRankingContext(query: context().query, includeSystemLocations: true), now: Clock().now()), baseline)
    }
    func testFallbackUnsupportedAndPermissionFailures() async throws {
        let fs = InMemoryFileSystem()
        let service = EnumerationSearchService(fileSystem: fs)
        for (request, expected) in [(SearchRequest(text: "tag:Work"), EnumerationSearchError.tagsUnavailable), (SearchRequest(text: "", scope: .recents), .recentsRequireMetadataSource)] {
            do {
                _ = try await service.search(SearchQueryParser.compile(request), roots: [], context: context())
                XCTFail("Expected unsupported metadata")
            } catch let error as EnumerationSearchError { XCTAssertEqual(error, expected) }
        }
        let root = URL(fileURLWithPath: "/")
        await fs.setFailure(.permissionDenied, at: root)
        let warning = expectation(description: "permission diagnostic")
        let denied = try await service.search(SearchSpecification(scope: .currentFolder(root), clauses: [], includeHidden: false), roots: [], context: context()) {
            XCTAssertEqual($0, .unreadable(root)); warning.fulfill()
        }
        await fulfillment(of: [warning], timeout: 1)
        XCTAssertTrue(denied.truncated); XCTAssertTrue(denied.results.isEmpty)
        let empty = try await service.search(SearchSpecification(scope: .thisMac, clauses: [], includeHidden: false), roots: [], context: context())
        XCTAssertTrue(empty.results.isEmpty)
    }
    func testDateAndSizeEdgesAndEscapes() throws {
        let spec = try SearchQueryParser.compile(SearchRequest(text: "modified:2026-01-01 size:>0 size:<2"))
        let start = Date(timeIntervalSince1970: 1767225600)
        for (date, size, expected) in [(start, Int64(1), true), (start.addingTimeInterval(86400), 1, false), (start, 0, false), (start, 2, false)] {
            XCTAssertEqual(spec.matches(FileEntry(url: URL(fileURLWithPath: "/x"), size: size, modificationDate: date)), expected)
        }
        XCTAssertThrowsError(try SearchQueryParser.compile(SearchRequest(text: "ext:...")))
        XCTAssertEqual(try SearchQueryParser.tokenize("a\\\"b"), ["a\"b"])
        let wildcard = try SearchQueryParser.compile(SearchRequest(text: "*"))
        XCTAssertTrue(wildcard.matches(FileEntry(url: URL(fileURLWithPath: "/literal*name"))))
        XCTAssertThrowsError(try FinderSavedSearchDocument(rawQuery: "x", searchScopes: ["computer"]))
    }

}
