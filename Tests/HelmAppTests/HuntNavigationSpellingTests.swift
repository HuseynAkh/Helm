#if os(macOS)
import Foundation
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmUI

/// Other apps ask Helm for paths as they were given: `open .` in a Terminal tab that went `cd ~/documents` sends
/// ~/documents, and a path can run through a link. Helm goes where the item really is, spelled as the disk spells it,
/// as it does for a typed path, so the path, the sidebar, Recent and the selection all match the listing.
final class HuntNavigationSpellingTests: XCTestCase {
    private var temp: TempDirectory!
    private var real: URL!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        real = temp.url.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: real.appendingPathComponent("inside.txt"))
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("Link"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("FileLink.txt"),
                                                   withDestinationURL: real.appendingPathComponent("inside.txt"))
    }
    override func tearDownWithError() throws { try temp?.remove() }

    private func standard(_ url: URL) -> String { PathSpelling.standardPath(url) }
    private func inTemp(_ path: String) -> URL { temp.url.appendingPathComponent(path) }

    func testAFileIsSpelledAsTheDiskSpellsIt() throws {
        // Only a disk that ignores case can answer for another case at all.
        guard try real.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false
        else { throw XCTSkip("This disk tells names apart by case") }
        XCTAssertEqual(standard(CanonicalPath.spelling(of: inTemp("REAL/Inside.TXT"))), standard(real.appendingPathComponent("inside.txt")))
        XCTAssertEqual(standard(CanonicalPath.resolve(inTemp("real"))), standard(real))
    }

    func testAFileThroughALinkedFolderIsInItsRealFolder() {
        XCTAssertEqual(standard(CanonicalPath.spelling(of: inTemp("Link/inside.txt"))), standard(real.appendingPathComponent("inside.txt")))
        XCTAssertEqual(standard(CanonicalPath.resolve(inTemp("Link"))), standard(real), "A linked folder opens where it really is")
    }

    func testALinkShownInItsFolderStaysTheLink() {
        // Finder's reveal of a link selects the link itself, not what it points at.
        XCTAssertEqual(standard(CanonicalPath.spelling(of: inTemp("FileLink.txt"))), standard(inTemp("FileLink.txt")))
        XCTAssertEqual(standard(CanonicalPath.spelling(of: inTemp("Link"))), standard(inTemp("Link")))
    }

    func testSomethingThatIsntThereIsLeftAsAsked() {
        let missing = inTemp("Missing/thing.txt")
        XCTAssertEqual(CanonicalPath.spelling(of: missing), missing)
        XCTAssertEqual(CanonicalPath.resolve(missing), missing)
    }
}
#endif
