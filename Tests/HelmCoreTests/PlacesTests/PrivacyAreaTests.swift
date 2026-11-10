import Foundation
import XCTest
@testable import HelmCore

/// Refusals are explained by where they happen: which folders macOS guards, and which Settings row opens each.
final class PrivacyAreaTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    private func kind(_ path: String) -> PrivacyArea.Kind? {
        PrivacyAreas.area(containing: home.appendingPathComponent(path), home: home)?.kind
    }

    func testGuardedFoldersAndTheirRows() {
        XCTAssertEqual(kind(".Trash"), .trash)
        XCTAssertEqual(kind("Documents/Reports/2026"), .documents)
        XCTAssertEqual(kind("Desktop"), .desktop)
        XCTAssertEqual(kind("Downloads/setup.dmg"), .downloads)
        XCTAssertEqual(kind("Music/Music/Media"), .mediaLibrary)
        XCTAssertEqual(kind("Movies/TV"), .mediaLibrary)
        XCTAssertEqual(kind("Library/Mail/V10"), .protectedData)
        XCTAssertEqual(kind("Library/Containers/com.example.notes"), .otherAppsData)
        XCTAssertEqual(kind("Library/Mobile Documents/com~apple~CloudDocs"), .cloudFiles)
        XCTAssertEqual(kind("Library/CloudStorage/GoogleDrive-me@example.com"), .cloudFiles)
        XCTAssertEqual(kind("Pictures/Photos Library.photoslibrary/originals"), .photosLibrary)

        let area = { (path: String) in PrivacyAreas.area(containing: self.home.appendingPathComponent(path), home: self.home) }
        XCTAssertEqual(area(".Trash")?.pane, .fullDiskAccess)
        XCTAssertEqual(area("Library/Mail")?.pane, .fullDiskAccess)
        XCTAssertEqual(area("Library/Containers/x")?.pane, .fullDiskAccess)
        XCTAssertEqual(area("Documents")?.pane, .filesAndFolders)
        XCTAssertEqual(area("Library/CloudStorage/x")?.pane, .filesAndFolders)
        XCTAssertEqual(area("Movies/TV")?.pane, .media)
        XCTAssertEqual(area("Pictures/Photos Library.photoslibrary")?.pane, .photos)
        // macOS never asks about the Trash or other apps' private data: only Full Disk Access opens them.
        XCTAssertEqual(area(".Trash")?.asksFirst, false)
        XCTAssertEqual(area("Library/Safari")?.asksFirst, false)
        XCTAssertEqual(area("Documents")?.asksFirst, true)
        XCTAssertEqual(area("Movies/TV")?.asksFirst, true)
    }

    func testPlacesThatAreNotGuarded() {
        // The media library is the app's own folder, not the whole of Movies or Music.
        XCTAssertNil(kind("Movies"))
        XCTAssertNil(kind("Music"))
        XCTAssertNil(kind("Movies/Holiday"))
        // A name that only starts the same isn't inside.
        XCTAssertNil(kind("Documents2"))
        XCTAssertNil(kind("DesktopStuff"))
        XCTAssertNil(kind(".Trash Old"))
        XCTAssertNil(PrivacyAreas.area(containing: home, home: home))
        XCTAssertNil(PrivacyAreas.area(containing: URL(fileURLWithPath: "/Volumes/Backup/Documents"), home: home))
        XCTAssertNil(PrivacyAreas.area(containing: URL(fileURLWithPath: "/Users/other/Documents"), home: home))
    }

    func testSpellingDoesNotChangeTheAnswer() {
        XCTAssertEqual(PrivacyAreas.area(containing: URL(fileURLWithPath: "/Users/me/documents/a"), home: home)?.kind, .documents)
        XCTAssertEqual(PrivacyAreas.area(containing: URL(fileURLWithPath: "/Users/me/Documents/"), home: home)?.kind, .documents)
        XCTAssertEqual(PrivacyAreas.area(containing: URL(fileURLWithPath: "/Users/me/Downloads/../Documents"), home: home)?.kind, .documents)
    }

    func testLocations() {
        XCTAssertEqual(PrivacyAreas.area(for: .trash, home: home)?.kind, .trash)
        XCTAssertEqual(PrivacyAreas.area(for: .trash, home: home)?.root.path, "/Users/me/.Trash")
        XCTAssertNil(PrivacyAreas.area(for: .recent, home: home))
        XCTAssertEqual(PrivacyAreas.area(for: .directory(home.appendingPathComponent("Desktop/a")), home: home)?.kind, .desktop)
    }

    func testAskingRootsAreTheFoldersAReadCanWaitOn() {
        let roots = Set(PrivacyAreas.askingRoots(home: home).map(\.path))
        XCTAssertTrue(roots.isSuperset(of: ["/Users/me/Desktop", "/Users/me/Documents", "/Users/me/Downloads",
                                            "/Users/me/Movies/TV", "/Users/me/Music/Music", "/Users/me/Library/CloudStorage"]))
        XCTAssertFalse(roots.contains("/Users/me/.Trash"))
        XCTAssertFalse(roots.contains("/Users/me/Library/Mail"))
    }

    func testWhichAreasAreGuardedAsAWholeAndWhatFullDiskAccessOpens() {
        let area = { (path: String) in PrivacyAreas.area(containing: self.home.appendingPathComponent(path), home: self.home) }
        // Each app's container and each cloud provider is asked about on its own.
        XCTAssertEqual(area("Library/Containers/com.example.notes")?.guardsEachChild, true)
        XCTAssertEqual(area("Library/Group Containers/group.example")?.guardsEachChild, true)
        XCTAssertEqual(area("Library/CloudStorage/Dropbox")?.guardsEachChild, true)
        XCTAssertEqual(area("Library/Mobile Documents/com~apple~CloudDocs")?.guardsEachChild, true)
        for path in ["Documents", "Desktop", "Downloads", "Movies/TV", "Pictures/Photos Library.photoslibrary", "Library/Mail", ".Trash"] {
            XCTAssertEqual(area(path)?.guardsEachChild, false, path)
        }
        // Full Disk Access covers the Trash, private data, other apps' data and the folders macOS asks about;
        // cloud providers and the media and photo libraries keep switches of their own.
        for path in [".Trash", "Library/Safari", "Library/Containers/x", "Documents", "Desktop", "Downloads"] {
            XCTAssertEqual(area(path)?.isOpenedByFullDiskAccess, true, path)
        }
        for path in ["Library/CloudStorage/Dropbox", "Music/Music", "Movies/TV", "Pictures/Photos Library.photoslibrary"] {
            XCTAssertEqual(area(path)?.isOpenedByFullDiskAccess, false, path)
        }
    }

    func testPanesNameTheirSettingsRows() {
        XCTAssertEqual(PrivacyPane.fullDiskAccess.anchor, "Privacy_AllFiles")
        XCTAssertEqual(PrivacyPane.filesAndFolders.anchor, "Privacy_FilesAndFolders")
        XCTAssertEqual(PrivacyPane.media.anchor, "Privacy_Media")
        XCTAssertEqual(PrivacyPane.photos.anchor, "Privacy_Photos")
        XCTAssertEqual(PrivacyPane.fullDiskAccess.title, "Full Disk Access")
        XCTAssertEqual(PrivacyPane.media.title, "Media & Apple Music")
    }
}
