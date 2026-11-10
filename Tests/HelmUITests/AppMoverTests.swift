#if os(macOS)
import Darwin
import Foundation
import XCTest
import HelmTestKit
@testable import HelmUI

/// When Helm offers to move itself into Applications: only from a disk image, a translocated copy, or anywhere outside
/// an Applications folder, however that folder's path is spelled, and never for HelmDev or a build Xcode just made.
final class AppPlacementTests: XCTestCase {
    private func decide(_ path: String, translocated: Bool = false, readOnly: Bool = false) -> AppPlacement {
        AppPlacement.decide(bundlePath: path, home: "/Users/me", isTranslocated: translocated, isOnReadOnlyVolume: readOnly)
    }

    func testOnlyTheApplicationsFoldersKeepHelmWhereItIs() {
        XCTAssertEqual(decide("/Applications/Helm.app"), .applications)
        XCTAssertEqual(decide("/Applications/Utilities/Helm.app"), .applications)
        XCTAssertEqual(decide("/Users/me/Applications/Helm.app"), .applications)
        XCTAssertEqual(AppPlacement.decide(bundlePath: "/Users/me/Applications/Helm.app", home: "/Users/me/", isTranslocated: false,
                                           isOnReadOnlyVolume: false), .applications)
        XCTAssertEqual(decide("/Users/me/Downloads/Helm.app"), .elsewhere)
        XCTAssertEqual(decide("/Users/me/Desktop/Helm.app"), .elsewhere)
        XCTAssertEqual(decide("/Applications Old/Helm.app"), .elsewhere)
        XCTAssertEqual(decide("/Volumes/Backup/Apps/Helm.app"), .elsewhere, "a disk that can be written to is just elsewhere")
    }

    /// Review finding onb-8: the same folder spelled another way still counts, so the copy in place isn't offered a move
    /// that would replace itself.
    func testApplicationsCountsHoweverItsSpelled() {
        XCTAssertEqual(decide("/applications/Helm.app"), .applications, "APFS doesn't care about case")
        XCTAssertEqual(decide("/System/Volumes/Data/Applications/Helm.app"), .applications, "the Data volume's firmlink")
        XCTAssertEqual(decide("/System/Volumes/Data/Users/me/Applications/Helm.app"), .applications)
        XCTAssertEqual(decide("//Applications//Helm.app/"), .applications)
        // Any folder called Applications is where apps live: a shared one, another person's, one on another disk.
        XCTAssertEqual(decide("/Users/Shared/Applications/Helm.app"), .applications)
        XCTAssertEqual(decide("/Users/someone/Applications/Helm.app"), .applications)
        XCTAssertEqual(decide("/Volumes/Apps/Applications/Helm.app"), .applications)
        // A folder the app's own settings name, such as where ~/Applications really is.
        XCTAssertEqual(AppPlacement.decide(bundlePath: "/Volumes/Apps/Helm.app", home: "/Users/me", isTranslocated: false,
                                           isOnReadOnlyVolume: false, applicationFolders: ["/Volumes/Apps"]), .applications)
    }

    func testBuildsFromXcodeAreNeverMoved() {
        XCTAssertEqual(decide("/Users/me/Library/Developer/Xcode/DerivedData/Helm-abc/Build/Products/Debug/Helm.app"), .developerBuild)
        XCTAssertEqual(decide("/Users/me/Code/Helm/App/build/Release/Helm.app"), .developerBuild)
        XCTAssertEqual(decide("/Users/me/Code/Helm/App/build/Debug/Helm.app"), .developerBuild)
        XCTAssertEqual(decide("/Users/me/Code/Helm/App/build/Products/Release/Helm.app"), .developerBuild)
        XCTAssertEqual(decide("/Users/me/Code/Helm/.build/arm64-apple-macosx/debug/Helm.app"), .developerBuild)
        XCTAssertFalse(AppPlacement.developerBuild.needsMove)
        XCTAssertFalse(AppPlacement.developerBuild.isTemporary)
        // A folder that only happens to be called build is just elsewhere.
        XCTAssertEqual(decide("/Users/me/build/Helm.app"), .elsewhere)
    }

    /// ~/Applications can be a symlink to another disk, and Helm is then launched from where it points.
    func testASymlinkedApplicationsFolderCounts() throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let apps = temp.url.appendingPathComponent("Apps", isDirectory: true)
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Helm.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Applications"), withDestinationURL: apps)
        XCTAssertEqual(AppPlacement.of(apps.appendingPathComponent("Helm.app"), home: home), .applications)
        XCTAssertEqual(AppPlacement.of(home.appendingPathComponent("Applications/Helm.app"), home: home), .applications)
        XCTAssertEqual(AppPlacement.of(apps.appendingPathComponent("Helm.app"), home: temp.url.appendingPathComponent("other")), .elsewhere)
    }

    func testDiskImagesAndTranslocatedCopiesMove() {
        XCTAssertEqual(decide("/Volumes/Helm/Helm.app", readOnly: true), .diskImage)
        XCTAssertEqual(decide("/private/var/folders/xy/T/AppTranslocation/0A1B-2C3D/d/Helm.app"), .translocated)
        XCTAssertEqual(decide("/Users/me/Downloads/Helm.app", translocated: true), .translocated)
        XCTAssertTrue(AppPlacement.diskImage.needsMove)
        XCTAssertTrue(AppPlacement.translocated.needsMove)
        XCTAssertTrue(AppPlacement.elsewhere.needsMove)
        XCTAssertFalse(AppPlacement.applications.needsMove)
        XCTAssertFalse(AppPlacement.notAnApp.needsMove)
        // Only a disk image and macOS's temporary copy go away by themselves.
        XCTAssertTrue(AppPlacement.diskImage.isTemporary)
        XCTAssertTrue(AppPlacement.translocated.isTemporary)
        XCTAssertFalse(AppPlacement.elsewhere.isTemporary)
    }

    func testHelmDevIsNeverMoved() throws {
        XCTAssertEqual(decide("/Users/me/Code/Helm/.build/debug"), .notAnApp)
        // The same answer from a real folder on disk, reading its volume as the app does.
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        XCTAssertEqual(AppPlacement.of(temp.url, home: temp.url), .notAnApp)
        let app = temp.url.appendingPathComponent("Helm.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(AppPlacement.of(app, home: temp.url.appendingPathComponent("home")), .elsewhere)
    }
}

/// Copying Helm into Applications, against folders of the test's own and a Trash of its own. Only the copy loses its
/// quarantine flag, and a copy it replaces goes to the Trash.
final class AppBundleCopierTests: XCTestCase {
    private var temp: TempDirectory!
    private let quarantine = AppBundleCopier.quarantine
    /// The test's own Trash: a replaced copy is moved here, never to the person's.
    private var trashFolder: URL { temp.url.appendingPathComponent("Trash", isDirectory: true) }

    override func setUpWithError() throws {
        temp = try TempDirectory()
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? temp.remove()
        super.tearDown()
    }

    private func copier(_ source: URL, into folders: [URL]) -> AppBundleCopier {
        let trash = trashFolder
        return AppBundleCopier(source: source, folders: folders) { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    /// A small app bundle as a download leaves it: quarantined throughout, with another attribute that has to stay.
    private func makeApp(in folder: String, saying text: String, named name: String = "Helm.app",
                         identifier: String = "com.helm.filemanager.dev") throws -> URL {
        let app = temp.url.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        let binary = app.appendingPathComponent("Contents/MacOS/Helm")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: binary)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Current").path, withDestinationPath: "MacOS")
        for path in [app.path, binary.path] {
            XCTAssertEqual(setxattr(path, quarantine, "0083;00000000;Safari;", 21, 0, 0), 0)
            XCTAssertEqual(setxattr(path, "com.example.keep", "yes", 3, 0, 0), 0)
        }
        return app
    }
    private func has(_ name: String, _ url: URL) -> Bool { getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    private func text(_ app: URL) -> String? { try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/Helm"), encoding: .utf8) }
    private func folder(_ name: String) throws -> URL {
        let url = temp.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCopiesIntoApplicationsAndLiftsOnlyTheQuarantine() throws {
        let source = try makeApp(in: "Volume", saying: "new")
        let applications = try folder("Applications")
        let copier = self.copier(source, into: [applications, temp.url.appendingPathComponent("home/Applications")])
        let target = try XCTUnwrap(copier.target())
        XCTAssertEqual(target.path, applications.appendingPathComponent("Helm.app").path)
        XCTAssertEqual(copier.copy(to: target), .moved(target))
        XCTAssertEqual(text(target), "new")
        let binary = target.appendingPathComponent("Contents/MacOS/Helm")
        XCTAssertFalse(has(quarantine, target))
        XCTAssertFalse(has(quarantine, binary))
        XCTAssertTrue(has("com.example.keep", target))
        XCTAssertTrue(has("com.example.keep", binary))
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("Contents/Current").path)
        XCTAssertEqual(link, "MacOS")
        // The copy it came from is left exactly as it was.
        XCTAssertTrue(has(quarantine, source))
        XCTAssertEqual(text(source), "new")
    }

    func testFallsBackToApplicationsInHomeWhenTheMainOneIsLocked() throws {
        let source = try makeApp(in: "Downloads", saying: "new")
        let applications = try folder("Applications")
        let home = try folder("home")
        chmod(applications.path, 0o555)
        defer { chmod(applications.path, 0o755) }
        let fallback = home.appendingPathComponent("Applications", isDirectory: true)
        let copier = self.copier(source, into: [applications, fallback])
        let target = try XCTUnwrap(copier.target())
        XCTAssertEqual(target.deletingLastPathComponent().path, fallback.path, "made if it isn't there yet")
        XCTAssertEqual(copier.copy(to: target), .moved(target))
        XCTAssertEqual(text(target), "new")
        XCTAssertFalse(has(quarantine, target))
        // Nowhere to write at all.
        let lockedHome = try folder("locked-home")
        chmod(lockedHome.path, 0o555)
        defer { chmod(lockedHome.path, 0o755) }
        XCTAssertNil(self.copier(source, into: [applications, lockedHome.appendingPathComponent("Applications")]).target())
        guard case .failed(let message) = copier.copy(to: lockedHome.appendingPathComponent("Applications/Helm.app")) else {
            return XCTFail("a copy into a locked folder can't succeed")
        }
        XCTAssertTrue(message.hasPrefix("Helm couldn’t be copied to "), message)
    }

    /// Review finding onb-2: the copy that's replaced goes to the Trash, never straight out of existence.
    func testAReplacedCopyGoesToTheTrash() throws {
        let source = try makeApp(in: "Volume", saying: "new")
        let older = try makeApp(in: "Applications", saying: "old")
        let copier = self.copier(source, into: [older.deletingLastPathComponent()])
        let target = try XCTUnwrap(copier.target())
        XCTAssertEqual(target.path, older.path)
        XCTAssertEqual(copier.copy(to: target), .moved(target))
        XCTAssertEqual(text(target), "new")
        XCTAssertFalse(has(quarantine, target))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["Helm.app"],
                       "nothing left beside it")
        XCTAssertEqual(text(trashFolder.appendingPathComponent("Helm.app")), "old", "the old copy is in the Trash")
    }

    /// Review finding onb-2: a download unpacked as "Helm 2.app" still goes in as Helm.app, so it meets the Helm already
    /// there instead of landing beside it with the same identifier.
    func testTheCopyIsAlwaysCalledHelm() throws {
        let source = try makeApp(in: "Downloads", saying: "new", named: "Helm 2.app")
        let applications = try folder("Applications")
        let copier = self.copier(source, into: [applications])
        let target = try XCTUnwrap(copier.target())
        XCTAssertEqual(target.lastPathComponent, "Helm.app")
        XCTAssertEqual(copier.copy(to: target), .moved(target))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Helm.app"])
    }

    /// If the old copy can't go to the Trash, nothing changes: no copy is half made, and the old one stays.
    func testACopyThatCantGoToTheTrashStaysWhereItIs() throws {
        let source = try makeApp(in: "Volume", saying: "new")
        let older = try makeApp(in: "Applications", saying: "old")
        struct Refused: Error {}
        let copier = AppBundleCopier(source: source, folders: [older.deletingLastPathComponent()]) { _ in throw Refused() }
        let target = try XCTUnwrap(copier.target())
        guard case .failed(let message) = copier.copy(to: target) else { return XCTFail("the Trash refused, so nothing moves") }
        XCTAssertTrue(message.contains("couldn’t be moved to the Trash, so nothing changed"), message)
        XCTAssertEqual(text(target), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["Helm.app"])
    }

    /// The copy that's running is never copied over itself, however the path to it is spelled.
    func testTheSameCopyIsNeverReplacedByItself() throws {
        let installed = try makeApp(in: "Applications", saying: "running")
        let link = temp.url.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: installed.deletingLastPathComponent())
        let throughLink = link.appendingPathComponent("Helm.app", isDirectory: true)
        XCTAssertTrue(AppBundleCopier.isSameItem(throughLink, installed))
        let copier = self.copier(throughLink, into: [installed.deletingLastPathComponent()])
        guard case .failed(let message) = copier.copy(to: installed) else { return XCTFail("it's the same copy") }
        XCTAssertTrue(message.hasPrefix("Helm is already in"), message)
        XCTAssertEqual(text(installed), "running")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trashFolder.path).isEmpty)
    }
}

/// Review finding onb-2: what Helm asks before replacing something called Helm.app, and what it refuses.
final class ReplaceDecisionTests: XCTestCase {
    private let mine = AppBundleInfo(identifier: "com.helm.filemanager.dev", version: "1.3", build: "50")

    func testSomethingElseCalledHelmIsLeftAlone() {
        guard case .refuse(let message) = ReplaceDecision.decide(existing: AppBundleInfo(identifier: "com.example.other", version: "9"),
                                                                 incoming: mine, folderName: "Applications") else {
            return XCTFail("another app isn't offered for replacing")
        }
        XCTAssertEqual(message, "Another app called Helm is in Applications, so rename or move it first.")
        // Something that can't be read as an app at all is left alone too.
        guard case .refuse = ReplaceDecision.decide(existing: nil, incoming: mine, folderName: "Applications") else {
            return XCTFail("an unreadable item isn't replaced")
        }
    }

    func testHelmIsReplacedOnlyAfterNamingBothVersions() {
        let older = AppBundleInfo(identifier: mine.identifier, version: "1.2", build: "45")
        XCTAssertEqual(ReplaceDecision.decide(existing: older, incoming: mine, folderName: "Applications"),
                       .ask(title: "Replace the Helm in Applications?",
                            detail: "Helm 1.2 (45) goes to the Trash, and Helm 1.3 (50) takes its place.",
                            replaceIsDefault: true))
        XCTAssertEqual(ReplaceDecision.decide(existing: mine, incoming: mine, folderName: "Applications"),
                       .ask(title: "Replace the Helm in Applications?",
                            detail: "Helm 1.3 (50) goes to the Trash, and Helm 1.3 (50) takes its place.",
                            replaceIsDefault: true))
        // A newer Helm there: Return keeps it.
        let newer = AppBundleInfo(identifier: mine.identifier, version: "1.10", build: "61")
        XCTAssertEqual(ReplaceDecision.decide(existing: newer, incoming: mine, folderName: "Applications"),
                       .ask(title: "Replace a newer Helm?",
                            detail: "Helm 1.10 (61) goes to the Trash, and Helm 1.3 (50) takes its place.",
                            replaceIsDefault: false))
    }

    func testVersionsCompareAsNumbers() throws {
        XCTAssertEqual(AppBundleInfo(identifier: nil, version: "1.10").isNewer(than: AppBundleInfo(identifier: nil, version: "1.9")), true)
        XCTAssertEqual(AppBundleInfo(identifier: nil, version: "1.2", build: "9").isNewer(than: AppBundleInfo(identifier: nil, version: "1.2", build: "10")), false)
        XCTAssertEqual(AppBundleInfo(identifier: nil, version: "1.2", build: "11").isNewer(than: AppBundleInfo(identifier: nil, version: "1.2", build: "10")), true)
        XCTAssertNil(AppBundleInfo(identifier: nil).isNewer(than: AppBundleInfo(identifier: nil, version: "1.0")))
        XCTAssertEqual(AppBundleInfo(identifier: nil, version: "2.0", build: "2.0").name, "Helm 2.0")
        XCTAssertEqual(AppBundleInfo(identifier: nil).name, "Helm")
        // Read straight from the bundle's Info.plist.
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let app = temp.url.appendingPathComponent("Helm.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.helm.filemanager.dev", "CFBundleShortVersionString": "1.3", "CFBundleVersion": "50"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(AppBundleInfo.read(app), mine)
        XCTAssertNil(AppBundleInfo.read(temp.url.appendingPathComponent("Missing.app")))
    }
}

/// Review finding onb-1: Helm's Dock tile opens this copy. Only the list is worked out here; nothing reads or writes the
/// real Dock.
@MainActor final class DockTileTests: XCTestCase {
    private let identifier = "com.helm.filemanager.dev"
    private let installed = URL(fileURLWithPath: "/Applications/Helm.app", isDirectory: true)

    private func app(_ name: String, _ identifier: String) -> [String: Any] {
        SystemFileViewerRole.tile(for: URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true), identifier: identifier)
    }
    private func helm(at path: String) -> [String: Any] {
        SystemFileViewerRole.tile(for: URL(fileURLWithPath: path, isDirectory: true), identifier: identifier)
    }
    private func paths(_ apps: [[String: Any]]) -> [String] { apps.compactMap(SystemFileViewerRole.tilePath) }

    func testHelmGoesFirstOnceAndStaysThere() throws {
        let mail = app("Mail", "com.apple.mail"), notes = app("Notes", "com.apple.Notes")
        // Not in the Dock: a new tile, first.
        let added = try XCTUnwrap(SystemFileViewerRole.placingFirst([mail, notes], identifier: identifier, app: installed))
        XCTAssertNil(added.from)
        XCTAssertEqual(paths(added.apps), ["/Applications/Helm.app", "/Applications/Mail.app", "/Applications/Notes.app"])
        // Further along: its own tile moves up.
        let moved = try XCTUnwrap(SystemFileViewerRole.placingFirst([mail, notes, helm(at: "/Applications/Helm.app")], identifier: identifier, app: installed))
        XCTAssertEqual(moved.from, 2)
        XCTAssertEqual(paths(moved.apps).first, "/Applications/Helm.app")
        // First already, however its path is spelled: nothing to do.
        XCTAssertNil(SystemFileViewerRole.placingFirst(moved.apps, identifier: identifier, app: installed))
        XCTAssertNil(SystemFileViewerRole.placingFirst([helm(at: "/System/Volumes/Data/Applications/Helm.app"), mail],
                                                       identifier: identifier, app: installed))
    }

    func testATileForAnotherCopyIsPointedAtThisOne() throws {
        let mail = app("Mail", "com.apple.mail")
        // Set up from a disk image that's since been ejected: first, by identifier, but opening the wrong copy.
        let stale = helm(at: "/Volumes/Helm/Helm.app")
        XCTAssertTrue(SystemFileViewerRole.isHelm(stale, identifier: identifier, app: installed))
        XCTAssertFalse(SystemFileViewerRole.opens(stale, app: installed))
        let fixed = try XCTUnwrap(SystemFileViewerRole.placingFirst([stale, mail], identifier: identifier, app: installed))
        XCTAssertEqual(fixed.from, 0)
        XCTAssertEqual(paths(fixed.apps), ["/Applications/Helm.app", "/Applications/Mail.app"], "replaced, not added beside it")
        XCTAssertTrue(SystemFileViewerRole.opens(fixed.apps[0], app: installed))
        // macOS's temporary copy, further along: replaced and moved first.
        let translocated = helm(at: "/private/var/folders/xy/T/AppTranslocation/0A1B/d/Helm.app")
        let both = try XCTUnwrap(SystemFileViewerRole.placingFirst([mail, translocated], identifier: identifier, app: installed))
        XCTAssertEqual(both.from, 1)
        XCTAssertEqual(paths(both.apps), ["/Applications/Helm.app", "/Applications/Mail.app"])
    }

    func testOnlyHelmsTileIsComparedByItsFile() {
        let tile = helm(at: "/Volumes/Helm/Helm.app")
        XCTAssertEqual(SystemFileViewerRole.tileKey(tile, helm: identifier), "com.helm.filemanager.dev /volumes/helm/helm.app")
        XCTAssertEqual(SystemFileViewerRole.tileKey(app("Mail", "com.apple.mail"), helm: identifier), "com.apple.mail")
        // A tile written as a plain path is read the same way.
        let plain: [String: Any] = ["tile-data": ["bundle-identifier": identifier,
                                                  "file-data": ["_CFURLString": "/Applications/Helm.app", "_CFURLStringType": 0]]]
        XCTAssertTrue(SystemFileViewerRole.opens(plain, app: installed))
        // One that doesn't say which file it opens is taken at its word.
        XCTAssertTrue(SystemFileViewerRole.opens(["tile-data": ["bundle-identifier": identifier]], app: installed))
    }
}

#endif
