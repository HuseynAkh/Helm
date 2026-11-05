// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmSearch

final class K13FallbackTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/root")
    private var context: SearchRankingContext {
        SearchRankingContext(query: SearchQuery(text: "", scope: .userFolders, bookmarkPaths: [],
            homeDirectory: root, lastDirectory: nil, showHidden: false, limit: 300))
    }

    /// F-046, B-026: a zero visit budget cannot return even the first matching file.
    func testZeroVisitBudget() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        try await fs.createFileExclusively(at: root.appendingPathComponent("a"), contents: Data())
        let result = try await EnumerationSearchService(fileSystem: fs).search(
            SearchSpecification(scope: .currentFolder(root), clauses: [], includeHidden: false),
            roots: [], context: context, visitLimit: 0)
        XCTAssertTrue(result.results.isEmpty)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.consideredCount, 0)
    }

    /// F-046, B-026: duplicate roots cannot duplicate visits or exhaust the budget early.
    func testDuplicateRootsShareVisitBudget() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        try await fs.createFileExclusively(at: root.appendingPathComponent("a"), contents: Data())
        let result = try await EnumerationSearchService(fileSystem: fs).search(
            SearchSpecification(scope: .thisMac, clauses: [], includeHidden: false),
            roots: [root, root.appendingPathComponent("../root")], context: context, visitLimit: 1)
        XCTAssertEqual(result.results.map(\.entry.name), ["a"])
        XCTAssertFalse(result.truncated)
    }

    /// F-043, F-046: a home search ignores caller roots outside the selected domain.
    func testHomeScopeDoesNotBroadenToProvidedRoots() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        let outside = URL(fileURLWithPath: "/outside")
        try await fs.createDirectory(at: outside)
        try await fs.createFileExclusively(at: outside.appendingPathComponent("secret"), contents: Data())
        let result = try await EnumerationSearchService(fileSystem: fs).search(
            SearchSpecification(scope: .home, clauses: [], includeHidden: false),
            roots: [outside], context: context)
        XCTAssertTrue(result.results.isEmpty)
        XCTAssertFalse(result.truncated)
    }

    /// F-044, F-046: hidden subtrees are skipped, not merely hidden from result rows.
    func testHiddenDirectoryDoesNotLeakDescendants() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        let hidden = root.appendingPathComponent(".hidden")
        try await fs.createDirectory(at: hidden)
        try await fs.createFileExclusively(at: hidden.appendingPathComponent("visible"), contents: Data())
        let service = EnumerationSearchService(fileSystem: fs)
        let omitted = try await service.search(
            SearchSpecification(scope: .currentFolder(root), clauses: [.name("visible")], includeHidden: false),
            roots: [], context: context)
        XCTAssertTrue(omitted.results.isEmpty)
        let included = try await service.search(
            SearchSpecification(scope: .currentFolder(root), clauses: [.name("visible")], includeHidden: true),
            roots: [], context: context)
        XCTAssertEqual(included.results.map(\.entry.name), ["visible"])
    }
}
