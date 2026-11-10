#if os(macOS)
import AppKit
import XCTest
import HelmCore
@testable import HelmApp
@testable import HelmUI

/// Reading what macOS sends the file viewer, from events built here, and telling which app sent one.
@MainActor final class ViewerEventTests: XCTestCase {
    private var folder: URL!
    private var one: URL { folder.appendingPathComponent("one.txt") }
    private var two: URL { folder.appendingPathComponent("two.txt") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in [one, two] { try Data(url.lastPathComponent.utf8).write(to: url) }
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        try super.tearDownWithError()
    }

    private func event(_ eventClass: UInt32, _ eventID: UInt32, direct: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(eventClass), eventID: AEEventID(eventID),
                                                      targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        if let direct { event.setParam(direct, forKeyword: keyDirectObject) }
        return event
    }
    private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
        return list
    }
    /// Paths as one spelling, since aliases and bookmarks come back through /private.
    private func paths(_ urls: [URL]) -> [String] { urls.map(PathSpelling.standardPath) }
    private func paths(of request: ViewerRequest?) -> [String] { paths(request?.items ?? []) }

    func testOpenDocumentsWithAListOfFileURLs() {
        // How NSWorkspace's Show in Finder reaches the file viewer.
        let request = ViewerEvent.request(from: event(kCoreEventClass, kAEOpenDocuments,
                                                      direct: list([NSAppleEventDescriptor(fileURL: one), NSAppleEventDescriptor(fileURL: two)])))
        guard case .open = request else { return XCTFail("not an open: \(String(describing: request))") }
        XCTAssertEqual(paths(of: request), paths([one, two]))
    }
    func testARevealOfOneFileURL() {
        let request = ViewerEvent.request(from: event(kAEMiscStandards, kAEMakeObjectsVisible, direct: NSAppleEventDescriptor(fileURL: one)))
        guard case .reveal = request else { return XCTFail("not a reveal: \(String(describing: request))") }
        XCTAssertEqual(paths(of: request), paths([one]))
    }
    func testAliasesAndBookmarks() throws {
        // An alias as AppleScript makes one, worked out here with no other app involved.
        var error: NSDictionary?
        let script = NSAppleScript(source: "return (POSIX file \"\(one.path)\") as alias")
        let alias = try XCTUnwrap(script?.executeAndReturnError(&error), "\(String(describing: error))")
        XCTAssertEqual(alias.descriptorType, DescType(typeAlias))
        let bookmark = try XCTUnwrap(NSAppleEventDescriptor(descriptorType: DescType(typeBookmarkData), data: try two.bookmarkData()))
        let request = ViewerEvent.request(from: event(kAEMiscStandards, kAEMakeObjectsVisible, direct: list([alias, bookmark])))
        XCTAssertEqual(paths(of: request), paths([one, two]))
    }
    func testPathsAndFileURLsAsText() {
        let request = ViewerEvent.request(from: event(kAEMiscStandards, kAEMakeObjectsVisible,
                                                      direct: list([NSAppleEventDescriptor(string: one.path),
                                                                    NSAppleEventDescriptor(string: two.absoluteString)])))
        XCTAssertEqual(paths(of: request), paths([one, two]))
    }
    func testNestedListsAndThingsThatAreNotFiles() {
        let nested = list([list([NSAppleEventDescriptor(fileURL: one)]), NSAppleEventDescriptor(int32: 7),
                           NSAppleEventDescriptor(string: "not a path"), NSAppleEventDescriptor(fileURL: two)])
        XCTAssertEqual(paths(ViewerEvent.urls(in: nested)), paths([one, two]))
        XCTAssertEqual(ViewerEvent.urls(in: NSAppleEventDescriptor.list()), [])
        XCTAssertEqual(ViewerEvent.request(from: event(kAEMiscStandards, kAEMakeObjectsVisible)), .reveal([]))
    }
    func testReopenAndOtherEvents() {
        // A reveal of nothing arrives as a reopen, as Archive Utility's last request does.
        XCTAssertEqual(ViewerEvent.request(from: event(kCoreEventClass, kAEReopenApplication)), .reopen)
        XCTAssertNil(ViewerEvent.request(from: event(kCoreEventClass, kAEQuitApplication)))
        XCTAssertNil(ViewerEvent.request(from: event(kCoreEventClass, kAEOpenApplication)))
    }
    func testABuiltEventNamesNoSender() {
        // macOS fills in the sender as it delivers an event; one built here has none, so it counts as unknown.
        XCTAssertNil(ViewerEvent.senderPID(of: event(kCoreEventClass, kAEOpenDocuments)))
    }
    func testSendersAreToldApartByBundle() throws {
        let directory = SenderDirectory()
        directory.running = { $0 == 101 ? "com.apple.archiveutility" : nil }
        // A helper that has quit: its executable still says which app it was, here a stand-in bundle.
        let app = folder.appendingPathComponent("Stand-in Helper.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.DiskImageMounter",
                                                                         "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = app.appendingPathComponent("Contents/MacOS/Stand-in Helper").path
        directory.executable = { $0 == 202 ? executable : ($0 == 303 ? "/usr/bin/true" : nil) }
        XCTAssertEqual(directory.identifier(of: 101), "com.apple.archiveutility")
        XCTAssertEqual(directory.identifier(of: 202), "com.apple.DiskImageMounter")
        XCTAssertNil(directory.identifier(of: 303), "a tool outside any app is unknown")
        XCTAssertNil(directory.identifier(of: 404))
        XCTAssertNil(directory.identifier(of: nil))
    }

    func testOnlyWhatGoesToFindersHelpersIsNoted() throws {
        func standIn(_ name: String, _ identifier: String) throws -> URL {
            let app = folder.appendingPathComponent("\(name).app", isDirectory: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"],
                                                          format: .xml, options: 0)
            try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
        let handoffs = HelperHandoffs()
        let archive = folder.appendingPathComponent("Photos.zip")
        handoffs.record([archive], handedTo: try standIn("Preview", "com.apple.Preview"))
        XCTAssertTrue(handoffs.ledger.handoffs.isEmpty, "an ordinary app isn't one of Finder's helpers")
        handoffs.record([archive], handedTo: try standIn("Archive Utility", "com.apple.archiveutility")) { _ in ["Photos.zip"] }
        XCTAssertEqual(handoffs.ledger.handoffs.map(\.item), [archive])
        XCTAssertEqual(handoffs.ledger.handoffs.first?.namesBefore, ["Photos.zip"])
        XCTAssertEqual(handoffs.route(.reopen, sender: "com.apple.archiveutility"),
                       .helm(reveal: true, handoff: handoffs.ledger.handoffs.first))
        handoffs.finished(helper: "com.apple.archiveutility")
        XCTAssertEqual(handoffs.route(.reopen, sender: "com.apple.archiveutility"), .finder([]))
    }
}
#endif
