// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class PathPresentationTests: XCTestCase {
    private func entry(_ path: String, kind: FileEntryKind = .regular) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: path), kind: kind)
    }
    func testRootAndCommittedDirectoryWithoutSelection() {
        for path in ["/", "/a", "/ab", "/a/nested"] {
            let url = URL(fileURLWithPath: path)
            let model = PathPresentation.build(location: .directory(url), selectedEntries: [])
            XCTAssertEqual(model.context, .directory)
            XCTAssertEqual(model.segments.last?.id.path, path)
            XCTAssertEqual(model.segments.first?.title, "/")
            XCTAssertEqual(model.segments.count, url.pathComponents.count)
        }
        let root = PathPresentation(location: .directory(URL(fileURLWithPath: "/")), selectedEntries: [])
        XCTAssertNil(root.intent(.reveal, segmentID: URL(fileURLWithPath: "/")))
    }

    func testSelectedResultAncestryAndRevealFromRecentOrSearchOverlay() {
        let file = entry("/elsewhere/nested/é space.txt")
        for location in [Location.recent, .directory(URL(fileURLWithPath: "/search-origin"))] {
            let model = PathPresentation.build(location: location, selectedEntries: [file])
            XCTAssertEqual(model.context, .selectedItem)
            XCTAssertEqual(model.segments.map(\.title), ["/", "elsewhere", "nested", "é space.txt"])
            XCTAssertEqual(model.intent(.reveal, segmentID: file.url),
                           .reveal(directory: file.url.deletingLastPathComponent(), selected: file.id))
            XCTAssertEqual(model.intent(.copyPath, segmentID: file.url), .copyPath(file.url.path))
            for action in [PathSegmentAction.navigate, .openTab, .dropTarget] {
                XCTAssertNil(model.intent(action, segmentID: file.url))
            }
        }
    }

    func testMixedParentsUseComponentCommonAncestorNotStringPrefix() {
        let unrelated = PathPresentation(location: .recent, selectedEntries: [entry("/a/one"), entry("/ab/two")])
        XCTAssertEqual(unrelated.context, .mixedSelection(count: 2))
        XCTAssertEqual(unrelated.segments.map(\.id.path), ["/"])
        let related = PathPresentation(location: .recent, selectedEntries: [entry("/a/x/one"), entry("/a/y/two")])
        XCTAssertEqual(related.segments.map(\.id.path), ["/", "/a"])
        let siblings = PathPresentation(location: .recent, selectedEntries: [entry("/a/one"), entry("/a/two")])
        XCTAssertEqual(siblings.segments.last?.id.path, "/a")
    }

    func testVirtualRootAndDisappearedSelectionNeverDefaultToHome() {
        for location in [Location.recent, .trash] {
            let selected = PathPresentation(location: location, selectedEntries: [entry("/missing/item")])
            XCTAssertEqual(selected.segments.last?.id.path, "/missing/item") // Supplied metadata; no existence probe.
            let removed = PathPresentation(location: location, selectedEntries: [])
            XCTAssertEqual(removed.context, .virtual(location))
            XCTAssertTrue(removed.segments.isEmpty)
            XCTAssertNil(removed.intent(.navigate, segmentID: URL(fileURLWithPath: "/missing")))
        }
        let current = URL(fileURLWithPath: "/committed")
        XCTAssertEqual(PathPresentation(location: .directory(current), selectedEntries: []).segments.last?.id, current)
    }

    func testSymlinkSpellingAndStandardizedIdentityWithoutIO() {
        let model = PathPresentation(location: .recent, selectedEntries: [entry("/link/folder", kind: .symlinkToDirectory)])
        let url = URL(fileURLWithPath: "/link/folder")
        XCTAssertEqual(model.segments.map(\.id.path), ["/", "/link", "/link/folder"])
        XCTAssertEqual(model.intent(.navigate, segmentID: url), .navigate(url))
        XCTAssertEqual(model.intent(.openTab, segmentID: url), .openTab(url))
        XCTAssertEqual(model.intent(.dropTarget, segmentID: url), .dropTarget(url))
        XCTAssertEqual(model.intent(.copyPath, segmentID: URL(fileURLWithPath: "/link/./folder")), .copyPath("/link/folder"))
        XCTAssertNil(model.intent(.navigate, segmentID: URL(fileURLWithPath: "/links")))
        let duplicate = PathPresentation(location: .recent, selectedEntries: [entry("/a/b"), entry("/a/./b")])
        XCTAssertEqual(duplicate.context, .selectedItem)
        let package = PathPresentation(location: .recent, selectedEntries: [entry("/a/App.app", kind: .package)])
        XCTAssertNil(package.intent(.dropTarget, segmentID: URL(fileURLWithPath: "/a/App.app")))
    }

    func testNonFileAndRemoteAuthorityRejectWholeProjection() throws {
        for string in ["https://example.com/a", "file://remote/a", "file:///a?q", "file:///a#f"] {
            let url = try XCTUnwrap(URL(string: string))
            let invalid = PathPresentation(location: .recent, selectedEntries: [entry("/valid"), FileEntry(url: url)])
            XCTAssertEqual(invalid.context, .invalidURL)
            XCTAssertTrue(invalid.segments.isEmpty)
            XCTAssertEqual(PathPresentation(location: .directory(url), selectedEntries: []).context, .invalidURL)
            XCTAssertNil(invalid.intent(.copyPath, segmentID: url))
        }
    }
}
