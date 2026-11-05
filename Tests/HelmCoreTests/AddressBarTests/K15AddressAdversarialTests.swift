// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class K15AddressAdversarialTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/test")
    private let current = URL(fileURLWithPath: "/work/deep")
    private func path(_ text: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(PathEntry.commitURL(text: text, currentDirectory: current, home: home)?.path,
                       expected, "F-015/B-054", file: file, line: line)
    }
    /// F-015/B-054: Root path resolution.
    func testRoot() { path("/", "/") }
    /// F-015/B-054: TrailingSlash path resolution.
    func testTrailingSlash() { path("/a/", "/a") }
    /// F-015/B-054: RepeatedSlash path resolution.
    func testRepeatedSlash() { path("/a///b/", "/a/b") }
    /// F-015/B-054: Parent path resolution.
    func testParent() { path("../", "/work") }
    /// F-015/B-054: AboveRoot path resolution.
    func testAboveRoot() { path("../../../../", "/") }
    /// F-015/B-054: Dot path resolution.
    func testDot() { path("./", "/work/deep") }
    /// F-015/B-054: Tilde path resolution.
    func testTilde() { path("~", "/home/test") }
    /// F-015/B-054: TildeParent path resolution.
    func testTildeParent() { path("~/../", "/home") }
    /// F-015/B-054: LiteralTildeUser path resolution.
    func testLiteralTildeUser() { path("~nobody", "/work/deep/~nobody") }
    /// F-015/B-054: Whitespace path resolution.
    func testWhitespace() { path(" \n\t ", "/home/test") }
    /// F-015/B-054: EmbeddedSpace path resolution.
    func testEmbeddedSpace() { path("a b", "/work/deep/a b") }
    /// F-015/B-054: Unicode path resolution.
    func testUnicode() { path("文書/📁", "/work/deep/文書/📁") }
    /// F-015: NUL must never reach URL validation.
    func testEmbeddedNulRejected() { XCTAssertNil(PathEntry.commitURL(text: "a\0b", currentDirectory: current, home: home)) }
    /// F-016: uncommitted names retain whitespace and long Unicode prefixes.
    func testLongPrefixPreserved() {
        let text = String(repeating: "é", count: 8192) + " "
        XCTAssertEqual(PathEntry(text: text, currentDirectory: current, home: home).prefix, text)
    }
    private func capped(_ count: Int, root: Bool = false) throws {
        let parent = root ? "/" : "/work/"
        let request = try XCTUnwrap(PathCompletionEngine.request(for: parent, currentDirectory: current, home: home,
                                                                showHidden: false, generation: Generation()))
        let children = (0..<count).reversed().map { index in
            CompletionCandidate(name: "item\(index)", url: URL(fileURLWithPath: parent + "item\(index)"), isDirectory: false)
        }
        let rows = PathCompletionEngine.rows(for: request, children: children)
        XCTAssertEqual(rows.count, min(count, 50) + (root ? 0 : 1), "F-017")
        XCTAssertEqual(rows.filter(\.isParentLink).count, root ? 0 : 1)
        XCTAssertEqual(Set(rows.map(\.path)).count, rows.count)
    }
    /// F-017: child cap excludes the parent row.
    func testCap0() throws { try capped(0) }
    /// F-017: child cap excludes the parent row.
    func testCap1() throws { try capped(1) }
    /// F-017: child cap excludes the parent row.
    func testCap49() throws { try capped(49) }
    /// F-017: child cap excludes the parent row.
    func testCap50() throws { try capped(50) }
    /// F-017: child cap excludes the parent row.
    func testCap51() throws { try capped(51) }
    /// F-017: child cap excludes the parent row.
    func testCap10000() throws { try capped(10000) }
    /// F-017/B-110: root never offers a parent row.
    func testRootCap() throws { try capped(51, root: true) }
    /// F-016: directory sorting must precede the cap, even if directories enumerate last.
    func testDirectoryAfterHugeFilePrefixWinsCap() throws {
        let request = try XCTUnwrap(PathCompletionEngine.request(for: "/work/", currentDirectory: current, home: home,
                                                                showHidden: false, generation: Generation()))
        var children = (0..<2000).map { CompletionCandidate(name: "a\($0)", url: current.appendingPathComponent("a\($0)"), isDirectory: false) }
        children.append(CompletionCandidate(name: "z", url: current.appendingPathComponent("z"), isDirectory: true))
        XCTAssertEqual(PathCompletionEngine.rows(for: request, children: children).dropFirst().first?.name, "z")
    }
    /// B-052: stale success and failure cannot replace fresh text or validation.
    func testLateResponsesAfterEditAndReturn() {
        var state = AddressEditor.reduce(AddressEditorState(currentDirectory: current, home: home), .beginEditing).0
        let old = state.generation
        state = AddressEditor.reduce(state, .textChanged("/fresh")).0
        state = AddressEditor.reduce(state, .returnKey).0
        let pending = state
        state = AddressEditor.reduce(state, .completions(old, [CompletionRow(name: "old", path: "/old", isDirectory: true)])).0
        state = AddressEditor.reduce(state, .completionFailed(old, "old failure")).0
        state = AddressEditor.reduce(state, .validated(old, URL(fileURLWithPath: "/old"), .directory)).0
        XCTAssertEqual(state, pending)
    }
    /// F-019/B-052: successive drills keep the generation issued with each request.
    func testTabTabTabDrillShowsLastDirectory() {
        var state = AddressEditor.reduce(AddressEditorState(currentDirectory: current, home: home), .beginEditing).0
        for depth in 1...3 {
            let path = "/work/deep/" + Array(repeating: "child", count: depth).joined(separator: "/")
            state = AddressEditor.reduce(state, .completions(state.generation, [CompletionRow(name: "child", path: path, isDirectory: true)])).0
            let (next, effects) = AddressEditor.reduce(state, .tab)
            state = next
            XCTAssertEqual(state.text, path + "/")
            XCTAssertTrue(effects.contains { if case .requestCompletions(let request) = $0 { return request.generation == state.generation }; return false })
        }
    }
    /// F-023: canonical Unicode equivalence must not corrupt the ghost suffix.
    func testCanonicalUnicodeGhost() {
        let row = CompletionRow(name: "café.txt", path: "/café.txt", isDirectory: false)
        XCTAssertEqual(PathCompletionEngine.ghostSuffix(typed: "/cafe\u{301}", selected: row, caretAtEnd: true), ".txt")
    }
}
