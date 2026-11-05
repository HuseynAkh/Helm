// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
import HelmTestKit
@testable import HelmFileSystem
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class TagsTests: XCTestCase {
    private let red = FinderTag(name: "Work", colorIndex: 6)

    func testNativeRoundTrip() async throws {
        try await roundTrip(parent: FileManager.default.temporaryDirectory)
    }

    #if os(Linux)
    func testSharedMemoryFilesystem() async throws {
        guard FileManager.default.fileExists(atPath: "/dev/shm") else { throw XCTSkip("No /dev/shm") }
        try await roundTrip(parent: URL(fileURLWithPath: "/dev/shm"))
    }
    #endif

    private func roundTrip(parent: URL) async throws {
        let directory = try TempDirectory(parent: parent)
        let file = directory.url.appendingPathComponent("fixture")
        let contents = Data("unchanged".utf8)
        try contents.write(to: file)
        let native = NativeTagAttributes()
        #if os(Linux)
        let other = "user.helm-k20-fixture"
        #else
        let other = "org.helm.k20-fixture"
        #endif
        do { try native.write(path: file.path, name: other, data: contents) }
        catch TagAdapterError.unsupportedFilesystem { throw XCTSkip("Fixture filesystem lacks user xattrs") }
        let unknown = FinderTag(rawValue: "Future\nunknown")
        try native.write(path: file.path, name: XattrTagStorage.attributeName,
                         data: FinderTagCodec.encode(TagSet(tags: [unknown])))
        let storage = XattrTagStorage()
        let item = ItemID(url: file)
        try await storage.apply(.add(red), to: item)
        try await storage.apply(.add(red), to: item)
        let added = try await storage.tags(for: item)
        XCTAssertEqual(added.tags, [unknown, red])
        try await storage.apply(.remove(red), to: item)
        let remaining = try await storage.tags(for: item)
        XCTAssertEqual(remaining.tags, [unknown])
        XCTAssertEqual(try native.read(path: file.path, name: other), contents)
        XCTAssertTrue(try native.names(path: file.path).contains(other))
        XCTAssertEqual(try Data(contentsOf: file), contents)
        try await storage.apply(.remove(unknown), to: item)
        XCTAssertNil(try native.read(path: file.path, name: XattrTagStorage.attributeName))
        try await storage.apply(.remove(red), to: item)
        // Fixtures intentionally retained: session instruction forbids deletion.
    }

    func testMissingFile() async throws {
        let item = ItemID(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for edit in [false, true] {
            do {
                if edit { try await XattrTagStorage().apply(.add(red), to: item) }
                else { _ = try await XattrTagStorage().tags(for: item) }
                XCTFail("Expected missing file")
            } catch { XCTAssertEqual(error as? TagAdapterError, .notFound) }
        }
    }

    func testPOSIXMappingAndFakeFailures() async throws {
        let cases: [(Int32, TagAdapterError)] = [(ENOTSUP, .unsupportedFilesystem), (ENOSYS, .unsupportedFilesystem), (EOPNOTSUPP, .unsupportedFilesystem),
            (EPERM, .permissionDenied), (EACCES, .permissionDenied), (EROFS, .permissionDenied),
            (ENOENT, .notFound), (ENOTDIR, .notFound), (EIO, .system(EIO))]
        for (code, expected) in cases {
            XCTAssertEqual(TagAdapterError.fromPOSIX(code), expected)
            let storage = XattrTagStorage(access: ScriptedAttributes(errorCode: code))
            do { try await storage.apply(.add(red), to: ItemID(rawValue: "/fixture")); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? TagAdapterError, expected) }
        }
    }

    func testConcurrentChangeIsMergedAndPersistentConflictFails() async throws {
        let first = try FinderTagCodec.encode(TagSet())
        let unknown = FinderTag(rawValue: "Unknown\n99")
        let second = try FinderTagCodec.encode(TagSet(tags: [unknown]))
        let fake = ScriptedAttributes(reads: [first, second, second, second])
        let storage = XattrTagStorage(access: fake)
        try await storage.apply(.add(red), to: ItemID(rawValue: "/fixture"))
        XCTAssertEqual(try FinderTagCodec.decode(XCTUnwrap(fake.written)).tags, [unknown, red])
        let conflict = ScriptedAttributes(reads: [first, second, first, second, first, second])
        do {
            try await XattrTagStorage(access: conflict).apply(.add(red), to: ItemID(rawValue: "/fixture"))
            XCTFail("Expected conflict")
        } catch { XCTAssertEqual(error as? TagAdapterError, .conflict) }
        XCTAssertNil(conflict.written)
    }

    func testMalformedMetadataIsNeverOverwritten() async throws {
        let fake = ScriptedAttributes(reads: [Data("broken".utf8)])
        do {
            try await XattrTagStorage(access: fake).apply(.add(red), to: ItemID(rawValue: "/fixture"))
            XCTFail("Expected codec error")
        } catch { XCTAssertNil(fake.written) }
    }

    func testBulkPartialFailuresAndDeduplication() async throws {
        let good = ItemID(rawValue: "/good")
        let bad = ItemID(rawValue: "/denied")
        let storage = InMemoryTagStorage(deniedItems: [bad])
        let applier = TagBulkApplier(storage: storage)
        let result = await applier.apply(.add(red), to: [good.url, bad.url, good.url])
        XCTAssertTrue(result.isPartialFailure)
        XCTAssertEqual(result.succeeded, [good])
        XCTAssertEqual(result.failures.map(\.item), [bad])
        let removed = await applier.apply(.remove(red), to: [good.url])
        XCTAssertEqual(removed.succeeded, [good])
        let tags = try await storage.tags(for: good)
        XCTAssertTrue(tags.tags.isEmpty)
        let empty = await applier.apply(.add(red), to: [])
        XCTAssertTrue(empty.outcomes.isEmpty)
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/file"))
        let rejected = await applier.apply(.add(red), to: [remote])
        XCTAssertEqual(rejected.failures.count, 1)
    }

    func testCompositeFallsBackOnlyForUnsupported() async throws {
        let item = ItemID(rawValue: "/fixture")
        let fallback = InMemoryTagStorage()
        let unsupported = XattrTagStorage(access: ScriptedAttributes(errorCode: ENOTSUP))
        let composite = CompositeTagStorage(primary: unsupported, fallback: fallback)
        try await composite.apply(.add(red), to: item)
        let tags = try await composite.tags(for: item)
        XCTAssertEqual(tags.tags, [red])
        let denied = CompositeTagStorage(primary: XattrTagStorage(access: ScriptedAttributes(errorCode: EACCES)), fallback: fallback)
        do { try await denied.apply(.remove(red), to: item); XCTFail("Expected denial") }
        catch { XCTAssertEqual(error as? TagAdapterError, .permissionDenied) }
        let unchanged = try await fallback.tags(for: item)
        XCTAssertEqual(unchanged.tags, [red])
        do { _ = try await CompositeTagStorage(primary: unsupported).tags(for: item); XCTFail("Expected unsupported") }
        catch { XCTAssertEqual(error as? TagAdapterError, .unsupportedFilesystem) }
    }
}

// Mutable fault script is accessed synchronously under its lock, including test observations.
private final class ScriptedAttributes: TagAttributeAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Data]
    private var value: Data?
    private let errorCode: Int32?
    init(reads: [Data] = [], errorCode: Int32? = nil) { self.reads = reads; self.errorCode = errorCode }
    var written: Data? { lock.lock(); defer { lock.unlock() }; return value }
    func read(path: String, name: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let errorCode { throw TagAdapterError.fromPOSIX(errorCode) }
        return reads.isEmpty ? value : reads.removeFirst()
    }
    func write(path: String, name: String, data: Data) throws {
        lock.lock(); defer { lock.unlock() }; value = data
    }
    func remove(path: String, name: String) throws {
        lock.lock(); defer { lock.unlock() }; value = nil
    }
    func names(path: String) throws -> [String] { [] }
}
