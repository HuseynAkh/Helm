#if os(macOS)
import XCTest
import HelmCore
@testable import HelmUI

/// A folder's default app is the one for every folder on the Mac, which Helm's own file viewer switch sets, so Open
/// With never changes it: no Always Open With and no Change Default App… for folders.
@MainActor final class OpenWithFolderDefaultsTests: XCTestCase {
    func testFoldersNeverChangeTheDefaultApp() {
        let file = FileEntry(url: URL(fileURLWithPath: "/Users/me/notes.txt"))
        let folder = FileEntry(url: URL(fileURLWithPath: "/Users/me/Projects", isDirectory: true), kind: .directory)
        let link = FileEntry(url: URL(fileURLWithPath: "/Users/me/link"), kind: .symlinkToDirectory)
        XCTAssertTrue(BrowserWindowController.canChangeDefaults(for: [file]))
        XCTAssertFalse(BrowserWindowController.canChangeDefaults(for: [folder]))
        XCTAssertFalse(BrowserWindowController.canChangeDefaults(for: [link]))
        XCTAssertFalse(BrowserWindowController.canChangeDefaults(for: [file, folder]), "a selection with a folder in it")
    }
}
#endif
