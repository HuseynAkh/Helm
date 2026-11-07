#if os(macOS)
import Foundation
import XCTest
import HelmCore
import UniformTypeIdentifiers
@testable import HelmUI

/// Drop rules, transparency and Open With ranking from the second interface pass.
@MainActor final class InterfacePassTests: XCTestCase {
    func testAFolderCannotGoInsideItself() {
        let reports = URL(fileURLWithPath: "/Users/me/Documents/Reports")
        XCTAssertTrue(BrowserWindowController.isSameOrInside(reports, reports))
        XCTAssertTrue(BrowserWindowController.isSameOrInside(reports.appendingPathComponent("2026"), reports))
        XCTAssertFalse(BrowserWindowController.isSameOrInside(URL(fileURLWithPath: "/Users/me/Documents"), reports))
        // A sibling whose name starts the same isn't inside it.
        XCTAssertFalse(BrowserWindowController.isSameOrInside(URL(fileURLWithPath: "/Users/me/Documents/Reports Old"), reports))
        // The two Unicode spellings of a name are one folder on a Mac.
        let composed = URL(fileURLWithPath: "/Users/me/caf\u{E9}"), decomposed = URL(fileURLWithPath: "/Users/me/cafe\u{301}")
        XCTAssertTrue(BrowserWindowController.isSame(composed, decomposed))
    }

    func testVolumesAreToldApartByPath() {
        XCTAssertEqual(BrowserWindowController.volumeKey(URL(fileURLWithPath: "/Users/me/a")), "/")
        XCTAssertEqual(BrowserWindowController.volumeKey(URL(fileURLWithPath: "/Volumes/USB/a")), "/Volumes/USB")
    }

    func testTransparencyClearsTheSidebarFirst() {
        XCTAssertEqual(WindowTints(percent: 50), WindowTints(percent: 50))
        let normal = WindowTints(percent: 50)
        XCTAssertEqual(normal.sidebar, 0, accuracy: 0.001)
        XCTAssertEqual(normal.content, 0.45, accuracy: 0.001) // Helm's own look.
        let solid = WindowTints(percent: 0)
        XCTAssertEqual(solid.sidebar, 1); XCTAssertEqual(solid.content, 1)
        let clear = WindowTints(percent: 100)
        XCTAssertEqual(clear.sidebar, 0); XCTAssertEqual(clear.content, 0)
        XCTAssertGreaterThan(WindowTints(percent: 25).content, WindowTints(percent: 25).sidebar)
    }

    /// A made-up app on disk, so ranking is tested without depending on what's installed.
    private func fakeApp(named name: String, documents: [[String: Any]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helm-apps-\(UUID().uuidString)")
        let app = root.appendingPathComponent("\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.helm.\(name)", "CFBundleName": name,
                                   "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "2.1",
                                   "CFBundleDocumentTypes": documents]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return app
    }

    func testAppsAreRankedByHowWellTheyClaimTheFile() throws {
        let swift = UTType("public.swift-source")
        let exact = try fakeApp(named: "Exact", documents: [["LSItemContentTypes": ["public.swift-source"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Owner"]])
        let family = try fakeApp(named: "Family", documents: [["LSItemContentTypes": ["public.plain-text"], "CFBundleTypeRole": "Viewer"]])
        let anything = try fakeApp(named: "Anything", documents: [["LSItemContentTypes": ["public.data"], "CFBundleTypeRole": "Editor"]])
        let byExtension = try fakeApp(named: "ByExtension", documents: [["CFBundleTypeExtensions": ["SWIFT"], "CFBundleTypeRole": "Editor"]])
        let refuses = try fakeApp(named: "Refuses", documents: [["LSItemContentTypes": ["public.swift-source"], "LSHandlerRank": "None"]])

        let exactChoice = ApplicationCatalog.describe(exact, type: swift, pathExtension: "swift")
        XCTAssertEqual(exactChoice.fit, 3); XCTAssertEqual(exactChoice.rank, 3); XCTAssertTrue(exactChoice.edits)
        XCTAssertEqual(exactChoice.version, "2.1")
        let familyChoice = ApplicationCatalog.describe(family, type: swift, pathExtension: "swift")
        XCTAssertEqual(familyChoice.fit, 2); XCTAssertFalse(familyChoice.edits)
        XCTAssertEqual(ApplicationCatalog.describe(anything, type: swift, pathExtension: "swift").fit, 1)
        XCTAssertEqual(ApplicationCatalog.describe(byExtension, type: swift, pathExtension: "swift").fit, 3)
        XCTAssertEqual(ApplicationCatalog.describe(refuses, type: swift, pathExtension: "swift").fit, 0)
        XCTAssertGreaterThan(exactChoice.score, familyChoice.score)
        XCTAssertEqual(familyChoice.detail, "Can view")
    }

    func testPressingTheHeaderSortCanReverseEveryField() {
        for field in SortField.all {
            let start = SortField.pressing(field.field, on: .defaultSort)
            let again = SortField.pressing(field.field, on: start)
            XCTAssertEqual(start.field, field.field)
            XCTAssertNotEqual(start.ascending, again.ascending, field.title)
        }
    }
}
#endif
