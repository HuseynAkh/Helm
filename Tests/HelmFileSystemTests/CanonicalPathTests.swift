import Foundation
import XCTest
import HelmCore
import HelmTestKit
import HelmFileSystem

/// The one real path of an item, which is what a folder is compared by before anything is done inside it.
final class CanonicalPathTests: XCTestCase {
    private var temp: TempDirectory!
    private var real: URL!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        real = temp.url.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: real.appendingPathComponent("inside.txt"))
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("Link"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("Dangling"),
                                                   withDestinationURL: temp.url.appendingPathComponent("gone"))
    }
    override func tearDownWithError() throws { try temp?.remove() }

    private func path(_ name: String) -> String { temp.url.appendingPathComponent(name).path }

    func testRealPathGoesThroughEveryLink() throws {
        let root = try XCTUnwrap(CanonicalPath.realPath(temp.url.path))
        // The temporary folder is itself reached through a link on a Mac, so the real root is what the rest is under.
        XCTAssertEqual(CanonicalPath.realPath(root), root, "A real path is its own real path")
        XCTAssertEqual(CanonicalPath.realPath(path("Real")), root + "/Real")
        XCTAssertEqual(CanonicalPath.realPath(path("Link")), root + "/Real", "A linked folder is where it points")
        XCTAssertEqual(CanonicalPath.realPath(path("Link/inside.txt")), root + "/Real/inside.txt")
        XCTAssertEqual(CanonicalPath.realPath(path("Real/../Link/./inside.txt")), root + "/Real/inside.txt")
        XCTAssertEqual(CanonicalPath.realPath(path("Real") + "/"), root + "/Real")
    }

    func testRealPathIsNilWhenAnyPartIsMissing() {
        XCTAssertNil(CanonicalPath.realPath(path("missing")))
        XCTAssertNil(CanonicalPath.realPath(path("missing/inside.txt")))
        XCTAssertNil(CanonicalPath.realPath(path("Real/missing.txt")))
        XCTAssertNil(CanonicalPath.realPath(path("Dangling")), "A link to nothing names nothing")
        XCTAssertNil(CanonicalPath.realPath(path("Real/inside.txt/below")), "A file has nothing inside it")
        XCTAssertNil(CanonicalPath.realPath(""))
    }

    func testResolveAnswersTheRealPathAndKeepsWhatItCannotResolve() throws {
        let root = try XCTUnwrap(CanonicalPath.realPath(temp.url.path))
        XCTAssertEqual(CanonicalPath.resolve(temp.url.appendingPathComponent("Link")).path, root + "/Real")
        let folder = CanonicalPath.resolve(temp.url.appendingPathComponent("Real"))
        XCTAssertEqual(folder.path, root + "/Real")
        XCTAssertTrue(folder.hasDirectoryPath)
        let file = CanonicalPath.resolve(temp.url.appendingPathComponent("Link/inside.txt"))
        XCTAssertEqual(file.path, root + "/Real/inside.txt")
        XCTAssertFalse(file.hasDirectoryPath)
        let missing = temp.url.appendingPathComponent("missing")
        XCTAssertEqual(CanonicalPath.resolve(missing), missing)
        XCTAssertEqual(CanonicalPath.spelling(of: missing), missing)
    }
}
