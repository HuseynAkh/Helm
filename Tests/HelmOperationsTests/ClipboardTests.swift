// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmOperations

final class ClipboardTests: XCTestCase {
    func testPartialCutAndExternalChanges() {
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
        let cut = ClipboardTransaction(mode: .cut, sources: [a, b], changeCount: 7)
        XCTAssertEqual(cut.acknowledging([a], currentChangeCount: 7)?.sources, [b])
        XCTAssertEqual(cut.acknowledging([a, b], currentChangeCount: 7)?.sources, [])
        XCTAssertNil(cut.acknowledging([a], currentChangeCount: 8))
        let copy = ClipboardTransaction(mode: .copy, sources: [a, b], changeCount: 7)
        XCTAssertEqual(copy.acknowledging([a], currentChangeCount: 7), copy)
    }
    @MainActor func testAdapterWritesOnlyUnchangedCutAndCapturesCounter() async throws {
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
        let board = TestPasteboard(urls: [a, b])
        let cut = ClipboardTransaction(mode: .cut, sources: [a, b], changeCount: 0)
        let remaining = try XCTUnwrap(cut.acknowledge([a], on: board))
        XCTAssertEqual(board.urls, [b]); XCTAssertEqual(remaining.changeCount, 1)
        XCTAssertNil(cut.acknowledge([b], on: board)); XCTAssertEqual(board.urls, [b])
        let empty = remaining.acknowledge([b], on: board)
        XCTAssertEqual(empty?.sources, []); XCTAssertEqual(board.urls, [])
        let copy = ClipboardTransaction(mode: .copy, sources: [a], changeCount: board.changeCount)
        _ = copy.acknowledge([a], on: board); XCTAssertEqual(board.changeCount, 2)
    }
    func testWebURLsNeverBecomeFiles() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/file"))
        XCTAssertTrue(ClipboardTransaction(mode: .cut, sources: [url], changeCount: 1).sources.isEmpty)
    }
}
@MainActor private final class TestPasteboard: FilePasteboard {
    var changeCount: Int = 0
    var urls: [URL]
    init(urls: [URL]) { self.urls = urls }
    func fileURLs() -> [URL] { urls }
    func replaceFileURLs(_ urls: [URL], ifChangeCount: Int) -> Int? {
        guard changeCount == ifChangeCount else { return nil }
        self.urls = urls; changeCount += 1; return changeCount
    }
}
