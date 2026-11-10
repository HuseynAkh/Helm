// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class F24LexicalPathTests: XCTestCase {
    private func session(sources: [DraggedItem] = []) -> SpringNavigationSession {
        SpringNavigationSession(original: SpringNavigationContext(tabID: TabID(), location: .recent),
                                clock: SystemHelmClock(), delay: 0, sources: sources)
    }

    func testEncodedSeparatorsNULAndInvalidUTF8Refused() throws {
        for spelling in ["a%2Fb", "a%2fb", "a%00b", "%FF", "%C0%AF"] {
            let url = try XCTUnwrap(URL(string: "file:///" + spelling))
            let model = PathPresentation(location: .directory(url), selectedEntries: [])
            XCTAssertEqual(model.context, .invalidURL, spelling)
            XCTAssertTrue(model.segments.isEmpty, spelling)
            for action in PathSegmentAction.allCases {
                XCTAssertNil(model.intent(action, segmentID: url), spelling)
            }
            XCTAssertThrowsError(try SharingSelectionSnapshot(urls: [url]), spelling)
            let selected = PathPresentation(location: .recent, selectedEntries: [FileEntry(url: url)])
            XCTAssertEqual(selected.context, .invalidURL, spelling)
            var state = session()
            let target = FileEntry(url: url, kind: .directory)
            state.beginHover(target)
            XCTAssertTrue(state.poll(openImmediately: true).isEmpty, spelling)
            XCTAssertNil(state.acceptDrop(target: target, destination: DropDestination(location: .directory(url)), allowedOperations: [.copy, .move]))
            var sourceState = session(sources: [DraggedItem(url: url)])
            let local = FileEntry(url: URL(fileURLWithPath: "/destination", isDirectory: true), kind: .directory)
            XCTAssertNil(sourceState.acceptDrop(target: local, destination: DropDestination(location: .directory(local.url)), allowedOperations: [.copy, .move]))
        }
    }

    func testLiteralPercentNamesAndUnicodeRoundTripExactlyOnce() throws {
        for path in ["/a%2Fb", "/a%2fb", "/a%00b", "/100%", "/a b", "/caf\u{00E9}", "/cafe\u{0301}", "/日本語", "/%2E%2E"] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let model = PathPresentation(location: .directory(url), selectedEntries: [])
            let leaf = try XCTUnwrap(model.segments.last)
            // macOS URLs decompose names; everywhere else the bytes round-trip exactly.
            XCTAssertEqual(leaf.id.path.split(separator: "/", omittingEmptySubsequences: true).map { PathSpelling.identity(String($0)) },
                           path.split(separator: "/", omittingEmptySubsequences: true).map { PathSpelling.identity(String($0)) })
            XCTAssertEqual(model.intent(.navigate, segmentID: url), .navigate(url))
            XCTAssertEqual(try SharingSelectionSnapshot(urls: [url]).urls, [url])
        }
    }

    func testEncodedDotAndParentPreserveExistingPolicy() throws {
        let dot = try XCTUnwrap(URL(string: "file:///a/%2e/b"))
        let parent = try XCTUnwrap(URL(string: "file:///a/%2E%2e/b"))
        let model = PathPresentation(location: .directory(dot), selectedEntries: [])
        XCTAssertEqual(model.segments.last?.id.path, "/a/b")
        let parentModel = PathPresentation(location: .directory(parent), selectedEntries: [])
        XCTAssertEqual(parentModel.segments.last?.id.path, "/a/../b")
        XCTAssertEqual(parentModel.intent(.copyPath, segmentID: parent), .copyPath("/a/../b"))
        XCTAssertNil(parentModel.intent(.navigate, segmentID: parent))
        XCTAssertEqual(try SharingSelectionSnapshot(urls: [parent]).urls, [parent])
        var state = session()
        state.beginHover(FileEntry(url: parent, kind: .directory))
        XCTAssertTrue(state.poll(openImmediately: true).isEmpty)
    }

#if canImport(Darwin)
    /// On macOS the two spellings name one file, so they are one location everywhere (Unicode ruling).
    func testUnicodeSpellingsAreOneNameOnMacOS() throws {
        let nfc = URL(fileURLWithPath: "/caf\u{00E9}", isDirectory: true)
        let nfd = URL(fileURLWithPath: "/cafe\u{0301}", isDirectory: true)
        let encodedNFC = try XCTUnwrap(URL(string: "file:///caf%C3%A9/"))
        XCTAssertEqual(nfc, nfd)
        XCTAssertEqual(try SharingSelectionSnapshot(urls: [nfc, nfd, nfc]).urls.count, 1)
        let model = PathPresentation(location: .directory(nfc), selectedEntries: [])
        XCTAssertEqual(model.intent(.navigate, segmentID: nfd), .navigate(try XCTUnwrap(model.segments.last).id))
        XCTAssertNotNil(model.intent(.navigate, segmentID: encodedNFC))
        let selected = PathPresentation(location: .recent, selectedEntries: [FileEntry(url: nfc), FileEntry(url: encodedNFC)])
        XCTAssertEqual(selected.context, .selectedItem)
    }

    func testUnicodeParentsShareTheirCommonFolderOnMacOS() {
        let entries = ["/caf\u{00E9}/one", "/cafe\u{0301}/two"].map {
            FileEntry(url: URL(fileURLWithPath: $0, isDirectory: false))
        }
        let model = PathPresentation(location: .recent, selectedEntries: entries)
        XCTAssertEqual(model.segments.map { PathSpelling.identity($0.id.path) },
                       ["/", "/cafe\u{0301}"].map(PathSpelling.identity))
    }

    func testSpringTreatsBothSpellingsAsOneFolderOnMacOS() throws {
        let identity = FileObjectIdentity(scope: "F24", object: "same-evidence")
        let nfc = FileEntry(url: URL(fileURLWithPath: "/caf\u{00E9}", isDirectory: true), kind: .directory, objectIdentity: identity)
        let nfd = FileEntry(url: URL(fileURLWithPath: "/cafe\u{0301}", isDirectory: true), kind: .directory, objectIdentity: identity)
        var state = session()
        state.beginHover(nfc)
        XCTAssertEqual(state.poll(openImmediately: true).count, 1)
        let load = try XCTUnwrap(state.pending)
        XCTAssertFalse(state.hoverOpened(request: load, target: nfd).isEmpty)
    }
#else
    func testUnicodeSpellingsStayDistinctInSharingAndMembership() throws {
        let nfc = URL(fileURLWithPath: "/caf\u{00E9}", isDirectory: true)
        let nfd = URL(fileURLWithPath: "/cafe\u{0301}", isDirectory: true)
        XCTAssertNotEqual(nfc, nfd)
        XCTAssertEqual(try SharingSelectionSnapshot(urls: [nfc, nfd, nfc]).urls, [nfc, nfd])
        let model = PathPresentation(location: .directory(nfc), selectedEntries: [])
        for action in PathSegmentAction.allCases {
            XCTAssertNil(model.intent(action, segmentID: nfd))
        }
        let selected = PathPresentation(location: .recent, selectedEntries: [FileEntry(url: nfc), FileEntry(url: nfd)])
        XCTAssertEqual(selected.context, .mixedSelection(count: 2))
    }

    func testUnicodeParentsHaveOnlyRootInCommon() {
        let entries = ["/caf\u{00E9}/one", "/cafe\u{0301}/two"].map {
            FileEntry(url: URL(fileURLWithPath: $0, isDirectory: false))
        }
        let model = PathPresentation(location: .recent, selectedEntries: entries)
        XCTAssertEqual(model.segments.map(\.id.path), ["/"])
    }

    func testSpringRejectsCrossSpellingLoadAndDropCompletion() throws {
        let identity = FileObjectIdentity(scope: "F24", object: "same-evidence")
        let nfc = FileEntry(url: URL(fileURLWithPath: "/caf\u{00E9}", isDirectory: true), kind: .directory, objectIdentity: identity)
        let nfd = FileEntry(url: URL(fileURLWithPath: "/cafe\u{0301}", isDirectory: true), kind: .directory, objectIdentity: identity)
        var state = session()
        state.beginHover(nfc)
        XCTAssertEqual(state.poll(openImmediately: true).count, 1)
        let load = try XCTUnwrap(state.pending)
        XCTAssertTrue(state.hoverOpened(request: load, target: nfd).isEmpty)
        var dropState = session(sources: [DraggedItem(url: URL(fileURLWithPath: "/source", isDirectory: false))])
        let request = try XCTUnwrap(dropState.acceptDrop(target: nfc, destination: DropDestination(location: .directory(nfc.url)), allowedOperations: [.copy, .move]))
        XCTAssertEqual(dropState.dropCompleted(request: request, success: true, destination: nfd), [.restore(dropState.original)])
    }
#endif
}
