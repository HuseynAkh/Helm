// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmSearch
final class T1SearchAdversarialTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/t1-search")
    private func editor() -> SearchCriteriaEditor {
        SearchCriteriaEditor(document: SavedSearchDocument(name: "日本語 🧭", request: SearchRequest(text: "report", scope: .home, includeHidden: true)))
    }
    private func context(limit: Int = 100) -> SearchRankingContext {
        SearchRankingContext(query: SearchQuery(text: "ignored", scope: .home, bookmarkPaths: [], homeDirectory: root, lastDirectory: nil, showHidden: false, limit: limit))
    }
    private func engine(_ fs: any FileSystem) -> SearchEngine {
        SearchEngine(fileSystem: fs, resolver: SearchRootResolver(home: root, computerRoots: [root, root]))
    }
    private func fixture(_ names: [String]) async throws -> InMemoryFileSystem {
        let fs = InMemoryFileSystem(); try await fs.createDirectory(at: root)
        for name in names { try await fs.createFileExclusively(at: root.appendingPathComponent(name), contents: Data([1])) }
        return fs
    }

    func testCriteriaAllRowClauseRoundTrips() throws {
        let rows: [SearchCriteriaRow] = [.nameContains("日本語 🧭"), .kind(.directory), .modifiedBefore(Date(timeIntervalSince1970: 10)), .modifiedOnOrAfter(Date(timeIntervalSince1970: 0)), .sizeLessThan(Int64.max), .sizeGreaterThan(0), .tag("Work"), .fileExtension("txt")]
        for row in rows { XCTAssertEqual(SearchCriteriaRow(clause: row.clause), row) }
    }
    func testCriteriaEditPreservesRequestMetadata() throws {
        var value = editor(); try value.append(.fileExtension("txt")); try value.append(.sizeGreaterThan(0))
        let document = try value.savedDocument()
        XCTAssertEqual(document.name, "日本語 🧭"); XCTAssertEqual(document.request.text, "report")
        XCTAssertEqual(document.request.scope, .home); XCTAssertTrue(document.request.includeHidden)
        XCTAssertEqual(document.request.filters, [.ext("txt"), .sizeGreaterThan(0)])
    }
    func testCriteriaEncodeDecodeRoundTrip() throws {
        var value = editor(); try value.append(.nameContains("café"))
        let data = try value.encode(); let decoded = try SavedSearchCodec.decode(data)
        XCTAssertEqual(decoded, try value.savedDocument())
        XCTAssertEqual(try SearchCriteriaEditor(document: decoded).encode(), data)
    }
    func testCriteriaInvalidRemoveIsAtomic() throws {
        var value = editor(); try value.append(.tag("Work"))
        for index in [Int.min, -1, 1, Int.max] {
            XCTAssertThrowsError(try value.remove(at: index)) { XCTAssertEqual($0 as? SearchCriteriaError, .invalidIndex) }
            XCTAssertEqual(value.rows, [.tag("Work")])
        }
    }
    func testCriteriaInvalidReplaceIsAtomic() throws {
        var value = editor(); try value.append(.kind(.regular))
        for index in [-1, 1, Int.max] { XCTAssertThrowsError(try value.replace(at: index, with: .tag("bad"))) }
        XCTAssertEqual(value.rows, [.kind(.regular)])
    }
    func testCriteriaReplaceAndRemove() throws {
        var value = editor(); try value.append(.tag("Work")); try value.append(.fileExtension("txt"))
        try value.replace(at: 0, with: .nameContains("a")); try value.remove(at: 1)
        XCTAssertEqual(try value.savedDocument().request.filters, [.name("a")])
        try value.remove(at: 0); XCTAssertTrue(try value.savedDocument().request.filters.isEmpty)
    }
    func testCriteriaOpaqueCannotMutate() throws {
        let document = try FinderSavedSearchDocument(rawQuery: "opaque != executable", searchScopes: ["/tmp"])
        var value = SearchCriteriaEditor(opaqueDocument: document)
        XCTAssertTrue(value.isReadOnly)
        XCTAssertThrowsError(try value.append(.tag("a")))
        XCTAssertThrowsError(try value.replace(at: 0, with: .tag("a")))
        XCTAssertThrowsError(try value.remove(at: 0)); XCTAssertThrowsError(try value.savedDocument())
        XCTAssertEqual(try value.encode(), FinderSavedSearchCodec.encode(document))
    }
    func testCriteriaRejectsNegativeSizeAtSave() throws {
        var value = editor(); try value.append(.sizeLessThan(-1))
        XCTAssertThrowsError(try value.savedDocument()); XCTAssertThrowsError(try value.encode())
    }
    func testEngineEmptyDirectoryProducesOneEmptySnapshot() async throws {
        let fs = try await fixture([]); var batches: [SearchRankedBatch] = []
        for await batch in engine(fs).search(SearchRequest(text: ""), context: context(), batchSize: 0) { batches.append(batch) }
        XCTAssertEqual(batches.count, 1); XCTAssertTrue(try XCTUnwrap(batches.first).results.isEmpty)
        XCTAssertFalse(try XCTUnwrap(batches.first).truncated)
    }
    func testEngineSingleUnicodeName() async throws {
        let fs = try await fixture(["日本語🧭.txt"])
        let result = try await engine(fs).collect(SearchRequest(text: "日本語"), context: context())
        XCTAssertEqual(result.results.map(\.entry.name), ["日本語🧭.txt"])
        XCTAssertEqual(result.results.map(\.rank), [0]); XCTAssertFalse(result.truncated)
    }
    func testEngineExactVisitBudget() async throws {
        let fs = try await fixture(["a", "b", "c"])
        let full = try await engine(fs).collect(SearchRequest(text: ""), context: context(), options: SearchWalkOptions(visitLimit: 3))
        XCTAssertEqual(full.results.count, 3); XCTAssertFalse(full.truncated)
        let limited = try await engine(fs).collect(SearchRequest(text: ""), context: context(), options: SearchWalkOptions(visitLimit: 2))
        XCTAssertEqual(limited.results.count, 2); XCTAssertTrue(limited.truncated)
    }
    func testEngineZeroBudgetIsDisclosed() async throws {
        let fs = try await fixture(["a"])
        let result = try await engine(fs).collect(SearchRequest(text: ""), context: context(), options: SearchWalkOptions(visitLimit: 0))
        XCTAssertTrue(result.results.isEmpty); XCTAssertTrue(result.truncated)
    }
    func testEngineSeededDeliveryDeterministic() async throws {
        let names = (0..<80).map { "report-\($0).txt" }
        let fs = try await fixture(names)
        let a = T1PermutedListingFixture(base: fs, seed: 7)
        let b = T1PermutedListingFixture(base: fs, seed: 91)
        for budget in [1, 17, 80] {
            let options = SearchWalkOptions(visitLimit: budget)
            let first = try await engine(a).collect(SearchRequest(text: "report"), context: context(), options: options)
            let second = try await engine(b).collect(SearchRequest(text: "report"), context: context(), options: options)
            XCTAssertEqual(first.results.map(\.entry.id), second.results.map(\.entry.id)); XCTAssertEqual(first.truncated, second.truncated)
        }
    }
    func testEngineStreamingCumulativePrefixes() async throws {
        let fs = try await fixture(["report-a", "report-b", "report-c", "report-d", "report-e"])
        let service = engine(fs); let request = SearchRequest(text: "report")
        let full = try await service.collect(request, context: context())
        var sizes: [Int] = []
        for await batch in service.search(request, context: context(), batchSize: 2) {
            sizes.append(batch.results.count)
            XCTAssertEqual(batch.results, Array(full.results.prefix(batch.results.count)))
        }
        XCTAssertEqual(sizes, [2, 4, 5])
    }
    func testEngineHiddenPolicy() async throws {
        let fs = try await fixture([".report", "report"])
        let visible = try await engine(fs).collect(SearchRequest(text: "report"), context: context())
        let all = try await engine(fs).collect(SearchRequest(text: "report", includeHidden: true), context: context())
        XCTAssertEqual(visible.results.map(\.entry.name), ["report"])
        XCTAssertEqual(Set(all.results.map(\.entry.name)), ["report", ".report"])
    }
    func testEnginePrecancelledCollect() async throws {
        let fs = try await fixture(["a"]); let service = engine(fs); let ctx = context()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await service.collect(SearchRequest(text: ""), context: ctx); XCTFail("cancelled search succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
    }
    func testEngineCancellationDuringIO() async throws {
        let fs = try await fixture(["a"]); await fs.setLatency(nanoseconds: 5_000_000_000)
        let service = engine(fs); let ctx = context()
        let task = Task { try await service.collect(SearchRequest(text: ""), context: ctx) }
        await Task.yield(); task.cancel()
        do { _ = try await task.value; XCTFail("cancelled search succeeded") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testEngineDuplicateRootsNotDuplicateResults() async throws {
        let fs = try await fixture(["a", "b"])
        let result = try await engine(fs).collect(SearchRequest(text: "", scope: .thisMac), context: context())
        XCTAssertEqual(result.results.count, 2); XCTAssertEqual(Set(result.results.map(\.entry.id)).count, 2)
    }
    func testEngineMissingRootPropagatesError() async throws {
        let fs = InMemoryFileSystem()
        do { _ = try await engine(fs).collect(SearchRequest(text: ""), context: context()); XCTFail("missing root succeeded") }
        catch { XCTAssertEqual(error as? FileSystemError, .notFound) }
    }
    func testEngineTagCriteriaFailsExplicitly() async throws {
        let fs = try await fixture(["a"])
        do { _ = try await engine(fs).collect(SearchRequest(text: "tag:Work"), context: context()); XCTFail("unsupported tag silently ignored") }
        catch { XCTAssertEqual(error as? EnumerationSearchError, .tagsUnavailable) }
    }
}
