import XCTest
import Foundation
import HelmCore
import HelmFileSystem
import HelmTestKit

final class FileSystemTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/folder")
    private func collect(_ fs: any FileSystem, _ url: URL, hidden: Bool = false) async throws -> [FileEntry] {
        var result: [FileEntry] = []
        for try await batch in fs.enumerate(url, options: EnumerationOptions(includeHidden: hidden, batchSize: 2)) {
            XCTAssertLessThanOrEqual(batch.count, 2)
            result += batch
        }
        return result
    }
    func testFakeOrderingHiddenCaseAndMissing() async throws {
        let fs = InMemoryFileSystem(caseSensitive: false)
        try await fs.createDirectory(at: root)
        for name in ["z", ".hidden", "A"] { try await fs.createFileExclusively(at: root.appendingPathComponent(name), contents: Data()) }
        let visible = try await collect(fs, root)
        XCTAssertEqual(visible.map(\.name), ["A", "z"])
        let all = try await collect(fs, root, hidden: true)
        XCTAssertEqual(all.count, 3)
        let exists = await fs.exists(root.appendingPathComponent("a"))
        XCTAssertTrue(exists)
        do { try await fs.createFileExclusively(at: root.appendingPathComponent("a"), contents: Data()); XCTFail("Collision accepted") }
        catch {}
        do { _ = try await collect(fs, URL(fileURLWithPath: "/missing")); XCTFail("Missing accepted") }
        catch { XCTAssertEqual(error as? FileSystemError, .notFound) }
        await fs.setFailure(.permissionDenied, at: root)
        do { _ = try await collect(fs, root); XCTFail("Denied accepted") }
        catch { XCTAssertEqual(error as? FileSystemError, .permissionDenied) }
    }
    func testSymlinkCyclesAndTreeSize() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try await fs.createSymbolicLink(at: a, destination: b)
        try await fs.createSymbolicLink(at: b, destination: a)
        try await fs.createSymbolicLink(at: root.appendingPathComponent("parent"), destination: root)
        try await fs.createFileExclusively(at: root.appendingPathComponent("file"), contents: Data([1, 2, 3]))
        let values = try await collect(fs, root)
        XCTAssertEqual(values.first { $0.name == "a" }?.kind, .danglingSymlink)
        XCTAssertEqual(values.first { $0.name == "parent" }?.kind, .symlinkToDirectory)
        var total: Int64 = 0
        for try await value in fs.sizeOfTree(at: root) { total = value }
        XCTAssertEqual(total, 3)
    }
    func testRealFileSystemMutationsAndTemplates() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let fs = LiveFileSystem()
        let templates = temp.url.appendingPathComponent("Templates")
        try await fs.createDirectory(at: templates)
        let file = templates.appendingPathComponent("File10")
        try await fs.createFileExclusively(at: file, contents: Data([1, 2, 3]))
        do { try await fs.createFileExclusively(at: file, contents: Data([9])); XCTFail("Overwrote") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
        try await fs.createDirectory(at: templates.appendingPathComponent("File2"))
        try await fs.createFileExclusively(at: templates.appendingPathComponent(".hidden"), contents: Data())
        let entries = try await TemplateProvider(fileSystem: fs, home: temp.url).templates()
        XCTAssertEqual(entries.map(\.name), ["File2", "File10"])
        let link = templates.appendingPathComponent("loop")
        try await fs.createSymbolicLink(at: link, destination: templates)
        let linkEntry = try await fs.entry(at: link)
        XCTAssertEqual(linkEntry.kind, .symlinkToDirectory)
        let copy = temp.url.appendingPathComponent("copy")
        try await fs.copyItem(at: file, to: copy)
        let moved = temp.url.appendingPathComponent("moved")
        try await fs.moveItem(at: copy, to: moved)
        try await fs.applyDirectoryMetadata(from: templates, to: temp.url)
        let backup = temp.url.appendingPathComponent("backup")
        try await fs.replaceItem(at: moved, with: file, backup: backup)
        XCTAssertEqual(try Data(contentsOf: backup), Data([1, 2, 3]))
        let properties = try await PropertiesLoader(fileSystem: fs).properties(for: moved)
        XCTAssertEqual(properties.size, 3)
        let capacity = try await fs.availableCapacity(of: temp.url)
        XCTAssertGreaterThan(capacity, 0)
        let volume = try await fs.volumeIdentifier(for: temp.url)
        XCTAssertFalse(volume.isEmpty)
        try await fs.removeItem(at: moved)
        let exists = await fs.exists(moved)
        XCTAssertFalse(exists)
    }
    func testHundredThousandEntriesAndCancellation() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        try await fs.seedFiles(in: root, count: 100_000)
        let start = Date()
        var count = 0
        for try await batch in fs.enumerate(root, options: EnumerationOptions(batchSize: 1024)) { count += batch.count }
        XCTAssertEqual(count, 100_000)
        let elapsed = Date().timeIntervalSince(start)
        print("K5 synthetic 100k enumeration: \(elapsed) seconds")
        XCTAssertLessThan(elapsed, 5)
        let task = Task {
            var seen = 0
            for try await batch in fs.enumerate(root, options: EnumerationOptions(batchSize: 1)) {
                try Task.checkCancellation()
                seen += batch.count
            }
            try Task.checkCancellation()
            return seen
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }
    func testFakeCopyMoveTrashAndReplacement() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        let source = root.appendingPathComponent("source")
        try await fs.createDirectory(at: source)
        try await fs.createFileExclusively(at: source.appendingPathComponent("child"), contents: Data([1]))
        let copy = root.appendingPathComponent("copy")
        try await fs.copyItem(at: source, to: copy)
        let copied = try await collect(fs, copy)
        XCTAssertEqual(copied.count, 1)
        let backup = root.appendingPathComponent("backup")
        try await fs.replaceItem(at: source, with: copy, backup: backup)
        let trashed = try await fs.trashItem(at: source)
        XCTAssertEqual(trashed?.path, "/.Trash/source")
        let present = await fs.exists(backup)
        XCTAssertTrue(present)
    }
}

extension FileSystemTests {
    func testRealDanglingAndLoopingLinksDoNotRecurse() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let fs = LiveFileSystem()
        let a = temp.url.appendingPathComponent("a"), b = temp.url.appendingPathComponent("b")
        try await fs.createSymbolicLink(at: a, destination: b)
        try await fs.createSymbolicLink(at: b, destination: a)
        let values = try await collect(fs, temp.url)
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.allSatisfy { $0.kind == .danglingSymlink })
        let names = try await fs.childNames(of: temp.url)
        XCTAssertEqual(names, ["a", "b"])
        let directory = await fs.isDirectory(a, resolvingSymlinks: true)
        XCTAssertFalse(directory)
    }
    func testInjectedLatencyCancelsBeforeMetadata() async throws {
        let fs = InMemoryFileSystem()
        await fs.setLatency(nanoseconds: 1_000_000_000)
        let task = Task { try await fs.entry(at: URL(fileURLWithPath: "/")) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Latency ignored cancellation") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
    }
    func testFailedReplacementRestoresOriginal() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let fs = LiveFileSystem()
        let original = temp.url.appendingPathComponent("original")
        try await fs.createFileExclusively(at: original, contents: Data([7]))
        do {
            try await fs.replaceItem(at: original, with: temp.url.appendingPathComponent("missing"),
                                     backup: temp.url.appendingPathComponent("backup"))
            XCTFail("Missing temporary accepted")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: original), Data([7]))
    }
}
