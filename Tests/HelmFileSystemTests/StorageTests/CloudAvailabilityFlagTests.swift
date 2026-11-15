import Foundation
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmFileSystem

/// Whether an item is on this Mac: the disk's own "in name only" flag first, for every provider, then iCloud's keys.
/// A test Mac holds no item with the flag, so the flag is stood in for.
final class CloudAvailabilityFlagTests: XCTestCase {
    func testADatalessItemIsEvicted() throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let file = temp.url.appendingPathComponent("Report.pdf"), folder = temp.url.appendingPathComponent("Shared")
        try Data("x".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var asked: [URL] = []
        for url in [file, folder] {
            let answer = try CloudAvailabilityReader.readMetadata(at: url) { asked.append($0); return true }
            XCTAssertEqual(answer, .evicted, url.lastPathComponent)
        }
        XCTAssertEqual(asked, [file, folder], "the flag of the item itself is what is read")
        // It decides even for a path whose keys can't be read at all: the flag is all a dataless item needs.
        let missing = temp.url.appendingPathComponent("gone")
        XCTAssertEqual(try CloudAvailabilityReader.readMetadata(at: missing) { _ in true }, .evicted)
    }

    func testNeitherTestApplyingIsUnknownAsBefore() throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let file = temp.url.appendingPathComponent("Notes.txt")
        try Data("x".utf8).write(to: file)
        // Not flagged and not in iCloud: no answer, as today, never "on this Mac".
        XCTAssertEqual(try CloudAvailabilityReader.readMetadata(at: file) { _ in false }, .unknown)
        XCTAssertEqual(try CloudAvailabilityReader.readMetadata(at: temp.url) { _ in false }, .unknown)
    }

    func testTheSystemFlagIsOffForAnOrdinaryItemAndALink() throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let file = temp.url.appendingPathComponent("Plain.txt"), link = temp.url.appendingPathComponent("Link")
        try Data("x".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertFalse(CloudAvailabilityReader.isDataless(file))
        XCTAssertFalse(CloudAvailabilityReader.isDataless(link))
        XCTAssertFalse(CloudAvailabilityReader.isDataless(temp.url.appendingPathComponent("gone")))
        // The listing's details carry the answer through unchanged.
        XCTAssertEqual(try CloudAvailabilityReader.readMetadata(at: file), .unknown)
        XCTAssertEqual(try MetadataReader().read(file).cloudAvailability, .unknown)
    }
}
