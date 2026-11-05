import Foundation
import XCTest
@testable import HelmCore

final class AddressBarPathEntryTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")
    private let current = URL(fileURLWithPath: "/work/projects")

    func testSlashAndPrefixParsing() {
        let slash = PathEntry(text: "/work/", currentDirectory: current, home: home)
        XCTAssertEqual(slash.directory.path, "/work")
        XCTAssertEqual(slash.prefix, "")
        XCTAssertTrue(slash.isSlashBrowsing)
        let prefix = PathEntry(text: "/work/Doc", currentDirectory: current, home: home)
        XCTAssertEqual(prefix.directory.path, "/work")
        XCTAssertEqual(prefix.prefix, "Doc")
        XCTAssertFalse(prefix.isSlashBrowsing)
    }

    func testTildeRelativeAndParentResolution() {
        for (text, expected) in [("~/Docs/", "/Users/test/Docs"), ("../Docs/", "/work/Docs"),
                                 ("./Docs", "/work/projects/Docs"), ("~", "/Users/test"),
                                 ("/../", "/"), ("//", "/")] {
            XCTAssertEqual(PathEntry(text: text, currentDirectory: current, home: home).resolvedURL.path, expected)
        }
        XCTAssertEqual(PathEntry(text: "..", currentDirectory: current, home: home).prefix, "..")
    }

    func testUnicodeSpacesAndVeryLongInput() {
        let name = "文書 📁 cafe\u{301} " + String(repeating: "a", count: 20_000)
        let entry = PathEntry(text: name, currentDirectory: current, home: home)
        XCTAssertEqual(entry.prefix, name)
        XCTAssertEqual(entry.directory.path, current.path)
        XCTAssertEqual(PathEntry(text: "My Folder ", currentDirectory: current, home: home).prefix, "My Folder ")
    }

    func testCommitTrimsAndEmptyMeansHomeAndRejectsNul() {
        XCTAssertEqual(PathEntry.commitURL(text: " \n ", currentDirectory: current, home: home), home)
        XCTAssertEqual(PathEntry.commitURL(text: " ../Docs \n", currentDirectory: current, home: home)?.path, "/work/Docs")
        XCTAssertNil(PathEntry.commitURL(text: "bad\0path", currentDirectory: current, home: home))
        XCTAssertEqual(PathEntry.directoryText(URL(fileURLWithPath: "/")), "/")
        XCTAssertEqual(PathEntry.directoryText(current), "/work/projects/")
    }
}
