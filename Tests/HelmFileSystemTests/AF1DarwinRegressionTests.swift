// DRAFT: pending review, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmFileSystem

#if os(macOS)
final class AF1DarwinRegressionTests: XCTestCase {
    func testSymlinkKindsRemainDistinctFromBookmarkAlias() async throws {
        let temp = try TempDirectory()
        let directory = temp.url.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = temp.url.appendingPathComponent("file")
        try Data().write(to: file)
        let reader = MetadataReader()
        for (name, target, kind) in [("directory-link", directory, FileEntryKind.symlinkToDirectory),
                                    ("file-link", file, .symlinkToFile),
                                    ("dangling", temp.url.appendingPathComponent("missing"), .danglingSymlink)] {
            let link = temp.url.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertEqual(try reader.read(link).kind, kind)
            XCTAssertEqual(try reader.read(link, resolveSymlinkTargets: false).kind, .danglingSymlink)
        }
        let alias = temp.url.appendingPathComponent("alias")
        let bookmark = try directory.bookmarkData(options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        XCTAssertEqual(try reader.read(alias).kind, .alias)
    }

    func testTagAttributesNeverFollowSymlink() throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("target")
        let link = temp.url.appendingPathComponent("link")
        try Data().write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let native = NativeTagAttributes()
        let attribute = XattrTagStorage.attributeName
        let original = try FinderTagCodec.encode(TagSet(tags: [FinderTag(name: "Target", colorIndex: 6)]))
        let replacement = try FinderTagCodec.encode(TagSet(tags: [FinderTag(name: "Link", colorIndex: 4)]))
        try native.write(path: file.path, name: attribute, data: original)
        XCTAssertNil(try native.read(path: link.path, name: attribute))
        XCTAssertFalse(try native.names(path: link.path).contains(attribute))
        do {
            try native.write(path: link.path, name: attribute, data: replacement)
            XCTAssertEqual(try native.read(path: link.path, name: attribute), replacement)
            XCTAssertTrue(try native.names(path: link.path).contains(attribute))
            try native.remove(path: link.path, name: attribute)
            XCTAssertNil(try native.read(path: link.path, name: attribute))
        } catch {
            // Some volumes refuse attributes on links; refusal must never touch the target.
            let failure = error as? TagAdapterError
            XCTAssertTrue(failure == .permissionDenied || failure == .unsupportedFilesystem, "\(error)")
        }
        XCTAssertEqual(try native.read(path: file.path, name: attribute), original)
    }

    func testMacMetadataProvidersAndTagAgreement() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("file")
        try Data().write(to: file)
        let expected = try temp.url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let sensitive = try await LiveFileSystem().isCaseSensitive(at: temp.url)
        XCTAssertEqual(sensitive, expected.volumeSupportsCaseSensitiveNames ?? false)
        let cloud = try await CloudAvailabilityReader().availability(at: file)
        XCTAssertEqual(cloud, .unknown)
        let volumes = try await VolumeReader().details()
        XCTAssertTrue(volumes.contains { $0.volume.url.path == "/" })
        let item = ItemID(url: file)
        let tag = FinderTag(name: "AF1", colorIndex: 6)
        try await XattrTagStorage().apply(.add(tag), to: item)
        let names = try await ResourceValuesTagStorage().tags(for: item)
        XCTAssertTrue(names.tags.contains { $0.name == tag.name })
    }
}
#endif
