import Foundation
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmFileSystem

#if os(macOS)
/// Bug hunt, views: the Kind column says what Finder's Kind says ("Folder", "Plain Text Document", "Application"),
/// not the type's own lower-case description ("folder", "text", "application").
final class HuntViewsKindTests: XCTestCase {
    func testTheKindIsFindersWordsWhenReadAndWhenListed() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let folder = temp.url.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let text = temp.url.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        let app = temp.url.appendingPathComponent("Tool.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let urls = [folder, text, temp.url.appendingPathComponent("Tool.app", isDirectory: true)]
        var finder: [String: String] = [:]
        for url in urls {
            let words = try url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
            finder[url.lastPathComponent] = try XCTUnwrap(words)
        }
        let reader = MetadataReader()
        for url in urls {
            XCTAssertEqual(try reader.read(url).localizedKindDescription, finder[url.lastPathComponent], url.lastPathComponent)
        }
        // The folder's listing reads the same words, from the keys it fetches in bulk.
        var listed: [String: String?] = [:]
        for try await batch in LiveFileSystem().enumerate(temp.url) {
            for entry in batch { listed[entry.name] = entry.localizedKindDescription }
        }
        for (name, words) in finder { XCTAssertEqual(listed[name] ?? nil, words, name) }
        // The type's own words, which the column used to show, are lower case for a folder.
        XCTAssertNotEqual(finder["Reports"], try folder.resourceValues(forKeys: [.contentTypeKey]).contentType?.localizedDescription)
    }
}
#endif
