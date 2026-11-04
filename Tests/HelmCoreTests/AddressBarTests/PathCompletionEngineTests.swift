// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

private actor AddressListingFake: DirectoryListing {
    var calls: [(URL, Bool)] = []
    let candidates: [CompletionCandidate]
    let fails: Bool
    init(_ candidates: [CompletionCandidate] = [], fails: Bool = false) {
        self.candidates = candidates; self.fails = fails
    }
    func children(of url: URL, includeHidden: Bool) async throws -> [CompletionCandidate] {
        calls.append((url, includeHidden))
        if fails { throw CocoaError(.fileReadNoSuchFile) }
        return candidates
    }
    func count() -> Int { calls.count }
    func hiddenRequested() -> Bool? { calls.last?.1 }
}

final class AddressBarCompletionEngineTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/work")
    private func request(_ prefix: String = "", slash: Bool = true, hidden: Bool = false) -> CompletionRequest {
        CompletionRequest(parent: base, prefix: prefix, isSlashBrowsing: slash, showHidden: hidden, generation: Generation())
    }
    private func candidate(_ name: String, directory: Bool = false, hidden: Bool = false, symlink: Bool = false) -> CompletionCandidate {
        CompletionCandidate(name: name, url: base.appendingPathComponent(name), isDirectory: directory,
                            isHidden: hidden, symlinkTargetIsDirectory: symlink)
    }

    func testParentFirstDirectoriesFirstNaturalSortAndHiddenPolicy() {
        let children = [candidate("z"), candidate("Folder10", directory: true), candidate("Folder2", directory: true),
                        candidate(".secret"), candidate("hidden", hidden: true), candidate("alias", symlink: true)]
        let rows = PathCompletionEngine.rows(for: request(), children: children)
        XCTAssertEqual(rows.map(\.name), ["..", "alias", "Folder2", "Folder10", "z"])
        XCTAssertEqual(rows.first?.completionText, "/")
        XCTAssertTrue(rows[1].isDirectory)
        XCTAssertEqual(rows[1].completionText, "/work/alias/")
        XCTAssertEqual(PathCompletionEngine.rows(for: request(hidden: true), children: children).count, 7)
    }

    func testCaseInsensitiveAnchoredUnicodeAndSpaceMatching() {
        let children = [candidate("Documents"), candidate("My Documents"), candidate("文書 📁"), candidate("My Folder")]
        XCTAssertEqual(PathCompletionEngine.rows(for: request("doc", slash: false), children: children).map(\.name), ["Documents"])
        XCTAssertEqual(PathCompletionEngine.rows(for: request("文", slash: false), children: children).map(\.name), ["文書 📁"])
        XCTAssertEqual(PathCompletionEngine.rows(for: request("my f", slash: false), children: children).map(\.name), ["My Folder"])
        XCTAssertTrue(PathCompletionEngine.rows(for: request("absent", slash: false), children: children).isEmpty)
    }

    func testCapAllowsFiftyChildrenPlusParentAndRootHasNoParent() {
        let children = (0..<80).map { candidate("file\($0)") }
        XCTAssertEqual(PathCompletionEngine.rows(for: request(), children: children).count, 51)
        XCTAssertEqual(PathCompletionEngine.rows(for: request(), children: children, limit: 1).map(\.name), ["..", "file0"])
        XCTAssertTrue(PathCompletionEngine.rows(for: request(), children: children, limit: -1).isEmpty)
        let root = CompletionRequest(parent: URL(fileURLWithPath: "/../"), prefix: "", isSlashBrowsing: true,
                                     showHidden: false, generation: Generation())
        XCTAssertEqual(PathCompletionEngine.rows(for: request(slash: false), children: children).count, 50)
        XCTAssertTrue(PathCompletionEngine.rows(for: request(), children: children, limit: 0).isEmpty)
        XCTAssertTrue(PathCompletionEngine.rows(for: root, children: children).allSatisfy { !$0.isParentLink })
        XCTAssertTrue(PathCompletionEngine.rows(for: root, children: []).isEmpty)
        XCTAssertEqual(PathCompletionEngine.rows(for: root, children: children).count, 50)
    }

    func testRequestRejectsEmptyAndNulAndResolvesRelative() throws {
        XCTAssertNil(PathCompletionEngine.request(for: "", currentDirectory: base, home: base, showHidden: false, generation: Generation()))
        XCTAssertNil(PathCompletionEngine.request(for: "a\0", currentDirectory: base, home: base, showHidden: false, generation: Generation()))
        let result = try XCTUnwrap(PathCompletionEngine.request(for: "Docs/", currentDirectory: base, home: base,
                                                               showHidden: true, generation: Generation(rawValue: 42)))
        XCTAssertEqual(result.parent.path, "/work/Docs")
        XCTAssertTrue(result.isSlashBrowsing)
        XCTAssertTrue(result.showHidden)
        XCTAssertEqual(result.generation.rawValue, 42)
    }

    func testGhostSuffixCaretParentCanonicalUnicodeAndTilde() {
        let row = CompletionRow(name: "Documents", path: "/work/Documents", isDirectory: true)
        XCTAssertEqual(PathCompletionEngine.ghostSuffix(typed: "/work/doc", selected: row, caretAtEnd: true), "uments/")
        XCTAssertNil(PathCompletionEngine.ghostSuffix(typed: "/work/doc", selected: row, caretAtEnd: false))
        XCTAssertNil(PathCompletionEngine.ghostSuffix(typed: "/other", selected: row, caretAtEnd: true))
        XCTAssertNil(PathCompletionEngine.ghostSuffix(typed: row.completionText, selected: row, caretAtEnd: true))
        XCTAssertNil(PathCompletionEngine.ghostSuffix(typed: "", selected: row, caretAtEnd: true))
        XCTAssertNil(PathCompletionEngine.ghostSuffix(typed: "/", selected: CompletionRow(name: "..", path: "/", isDirectory: true, isParentLink: true), caretAtEnd: true))
        XCTAssertEqual(PathCompletionEngine.ghostSuffix(typed: "~/doc", selected: row, caretAtEnd: true, currentDirectory: base, home: base), "uments/")
        XCTAssertEqual(PathCompletionEngine.ghostSuffix(typed: "doc", selected: row, caretAtEnd: true, currentDirectory: base, home: base), "uments/")
        XCTAssertEqual(PathCompletionEngine.acceptedText(row: row, typed: "~/doc", home: base), "~/Documents/")
        XCTAssertEqual(PathCompletionEngine.acceptedText(row: row, typed: "doc", home: base), "/work/Documents/")
        let unicode = CompletionRow(name: "café 📁", path: "/work/café 📁", isDirectory: true)
        XCTAssertEqual(PathCompletionEngine.ghostSuffix(typed: "/work/cafe\u{301}", selected: unicode, caretAtEnd: true), " 📁/")
        XCTAssertEqual(PathCompletionEngine.acceptedText(row: CompletionRow(name: "work", path: "/work", isDirectory: true), typed: "~", home: base), "~/")
    }

    func testAsyncListingRelistsAndPassesHiddenFlag() async throws {
        let fake = AddressListingFake([candidate("Docs", directory: true)])
        let engine = PathCompletionEngine(listing: fake)
        let first = try await engine.complete(request(hidden: true))
        let second = try await engine.complete(request(hidden: true))
        XCTAssertEqual(first, second)
        let count = await fake.count()
        let hidden = await fake.hiddenRequested()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(hidden, true)
    }

    func testNonexistentDirectoryThrowsAndCancellationPropagates() async {
        do {
            _ = try await PathCompletionEngine(listing: AddressListingFake(fails: true)).complete(request())
            XCTFail("Expected missing-directory error")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileReadNoSuchFile.rawValue) }
        let req = request()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PathCompletionEngine(listing: AddressListingFake()).complete(req)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
