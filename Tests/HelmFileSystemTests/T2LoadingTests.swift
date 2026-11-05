// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmTestKit

// F-035/B-014: gates expose entry and enumeration awaits without timing assumptions.
private actor T2EntryGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if released { return }; await withCheckedContinuation { waiter = $0 } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private struct T2ControlledFS: RecoverableDirectoryEnumerating {
    let root: URL
    let entryGate: T2EntryGate?
    let entered: XCTestExpectation?
    let enumerated: XCTestExpectation?
    let stream: AsyncThrowingStream<LoadEvent, Error>
    func entry(at url: URL) async throws -> FileEntry {
        entered?.fulfill()
        await entryGate?.wait()
        return FileEntry(url: url, kind: .directory)
    }
    func enumerateRecoverably(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<LoadEvent, Error> {
        enumerated?.fulfill(); return stream
    }
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func exists(_ url: URL) async -> Bool { true }
    func copyItem(at source: URL, to destination: URL) async throws { throw FileSystemError.unsupported }
    func moveItem(at source: URL, to destination: URL) async throws { throw FileSystemError.unsupported }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws { throw FileSystemError.unsupported }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws { throw FileSystemError.unsupported }
    func trashItem(at url: URL) async throws -> URL? { throw FileSystemError.unsupported }
    func removeItem(at url: URL) async throws { throw FileSystemError.unsupported }
    func createDirectory(at url: URL) async throws { throw FileSystemError.unsupported }
    func createFileExclusively(at url: URL, contents: Data) async throws { throw FileSystemError.unsupported }
    func createSymbolicLink(at url: URL, destination: URL) async throws { throw FileSystemError.unsupported }
    func createAlias(for url: URL, at destination: URL) async throws { throw FileSystemError.unsupported }
    func volumeIdentifier(for url: URL) async throws -> String { "memory" }
    func availableCapacity(of url: URL) async throws -> Int64 { 0 }
}
final class T2LoadingTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/t2")
    private let generation = Generation(rawValue: 73)
    private func collect(_ stream: AsyncStream<TabAction>) async -> [TabAction] {
        var values: [TabAction] = []; for await value in stream { values.append(value) }; return values
    }
    private func terminal(_ actions: [TabAction]) throws -> PresentationSnapshot {
        guard case .loadFinished(let stamp, let snapshot)? = actions.last else { throw FileSystemError.other("No terminal snapshot") }
        XCTAssertEqual(stamp, generation); return snapshot
    }
    private func fixture(_ events: [LoadEvent], error: FileSystemError? = nil) -> DirectoryLoadPipeline {
        let stream = AsyncThrowingStream<LoadEvent, Error> { c in
            for event in events { c.yield(event) }; c.finish(throwing: error)
        }
        return DirectoryLoadPipeline(fileSystem: T2ControlledFS(root: root, entryGate: nil, entered: nil, enumerated: nil, stream: stream))
    }
    func testCumulativeBatchSize1() async throws {
        let entries = (0..<103).reversed().map { FileEntry(url: root.appendingPathComponent("item\($0)")) }
        let loader = fixture(entries.map { .batch([$0]) })
        let result = try terminal(await collect(loader.load(.directory(root), generation: generation, options: LoadOptions(batchSize: 1))))
        XCTAssertEqual(result.sortedEntries.count, 103)
        XCTAssertEqual(result.sortedEntries.first?.name, "item0")
        XCTAssertEqual(result.sortedEntries.last?.name, "item102")
    }
    func testCumulativeBatchSize2() async throws {
        let entries = (0..<103).reversed().map { FileEntry(url: root.appendingPathComponent("item\($0)")) }
        let loader = fixture(entries.map { .batch([$0]) })
        let result = try terminal(await collect(loader.load(.directory(root), generation: generation, options: LoadOptions(batchSize: 2))))
        XCTAssertEqual(result.sortedEntries.count, 103)
        XCTAssertEqual(result.sortedEntries.first?.name, "item0")
        XCTAssertEqual(result.sortedEntries.last?.name, "item102")
    }
    func testCumulativeBatchSize17() async throws {
        let entries = (0..<103).reversed().map { FileEntry(url: root.appendingPathComponent("item\($0)")) }
        let loader = fixture(entries.map { .batch([$0]) })
        let result = try terminal(await collect(loader.load(.directory(root), generation: generation, options: LoadOptions(batchSize: 17))))
        XCTAssertEqual(result.sortedEntries.count, 103)
        XCTAssertEqual(result.sortedEntries.first?.name, "item0")
        XCTAssertEqual(result.sortedEntries.last?.name, "item102")
    }
    func testCumulativeBatchSize512() async throws {
        let entries = (0..<103).reversed().map { FileEntry(url: root.appendingPathComponent("item\($0)")) }
        let loader = fixture(entries.map { .batch([$0]) })
        let result = try terminal(await collect(loader.load(.directory(root), generation: generation, options: LoadOptions(batchSize: 512))))
        XCTAssertEqual(result.sortedEntries.count, 103)
        XCTAssertEqual(result.sortedEntries.first?.name, "item0")
        XCTAssertEqual(result.sortedEntries.last?.name, "item102")
    }
    func testHundredThousandDuplicateUpdates() async throws {
        let entries = (0..<100_000).map { FileEntry(url: root.appendingPathComponent("item\($0)")) }
        let loader = fixture([.batch(entries), .batch(Array(entries.prefix(100)))])
        let result = try terminal(await collect(loader.load(.directory(root), generation: generation)))
        XCTAssertEqual(result.sortedEntries.count, 100_000)
        XCTAssertEqual(result.sortedEntries.last?.name, "item99999")
        XCTAssertNotNil(result.index(of: ItemID(url: root.appendingPathComponent("item50000"))))
    }
    func testHiddenVisibilityFalse() async throws {
        let loader = fixture([.batch([FileEntry(url: root.appendingPathComponent("visible")), FileEntry(url: root.appendingPathComponent(".hidden"), isHidden: true)])])
        let result = try terminal(await collect(loader.load(.directory(root), generation: generation, options: LoadOptions(showHidden: false))))
        XCTAssertEqual(result.sortedEntries.count, 1)
        XCTAssertTrue(result.sortedEntries.contains { $0.name == "visible" })
    }
    func testHiddenVisibilityTrue() async throws {
        let loader = fixture([.batch([FileEntry(url: root.appendingPathComponent("visible")), FileEntry(url: root.appendingPathComponent(".hidden"), isHidden: true)])])
        let result = try terminal(await collect(loader.load(.directory(root), generation: generation, options: LoadOptions(showHidden: true))))
        XCTAssertEqual(result.sortedEntries.count, 2)
        XCTAssertTrue(result.sortedEntries.contains { $0.name == "visible" })
    }
    func testDuplicateIDLatestMetadataWins() async throws {
        let path = root.appendingPathComponent("same")
        let loader = fixture([.batch([FileEntry(url: path, size: 1)]), .batch([FileEntry(url: path, size: 9)])])
        let result = try terminal(await collect(loader.load(.directory(root), generation: generation)))
        XCTAssertEqual(result.sortedEntries.count, 1); XCTAssertEqual(result.sortedEntries.first?.size, 9)
    }
    func testPartialThenTimeout() async throws {
        let loader = fixture([.batch([FileEntry(url: root.appendingPathComponent("partial"))])], error: .timedOut)
        let actions = await collect(loader.load(.directory(root), generation: generation, options: LoadOptions(batchSize: 1)))
        guard case .loadFailed(let stamp, .timedOut)? = actions.last else { return XCTFail("Terminal error lost") }
        XCTAssertEqual(stamp, generation)
        XCTAssertFalse(actions.contains { if case .loadFinished = $0 { return true }; return false })
    }
    func testPartialThenPermission() async throws {
        let loader = fixture([.batch([FileEntry(url: root.appendingPathComponent("partial"))])], error: .permissionDenied)
        let actions = await collect(loader.load(.directory(root), generation: generation, options: LoadOptions(batchSize: 1)))
        guard case .loadFailed(let stamp, .permissionDenied)? = actions.last else { return XCTFail("Terminal error lost") }
        XCTAssertEqual(stamp, generation)
        XCTAssertFalse(actions.contains { if case .loadFinished = $0 { return true }; return false })
    }
    func testPartialThenMissing() async throws {
        let loader = fixture([.batch([FileEntry(url: root.appendingPathComponent("partial"))])], error: .notFound)
        let actions = await collect(loader.load(.directory(root), generation: generation, options: LoadOptions(batchSize: 1)))
        guard case .loadFailed(let stamp, .notFound)? = actions.last else { return XCTFail("Terminal error lost") }
        XCTAssertEqual(stamp, generation)
        XCTAssertFalse(actions.contains { if case .loadFinished = $0 { return true }; return false })
    }
    func testWarningsStillComplete() async throws {
        let loader = fixture([.warning("skipped"), .batch([FileEntry(url: root.appendingPathComponent("good"))])])
        let warning = expectation(description: "diagnostic")
        let result = try terminal(await collect(loader.load(.directory(root), generation: generation, diagnostic: { _ in warning.fulfill() })))
        await fulfillment(of: [warning], timeout: 2)
        XCTAssertEqual(result.sortedEntries.map(\.name), ["good"])
    }
    func testMonitorReloadOnlyCompleteSnapshot() async throws {
        let loader = fixture((0..<40).map { .batch([FileEntry(url: root.appendingPathComponent("f\($0)"))]) })
        let actions = await collect(loader.reload(.directory(root), monitorGeneration: generation, options: LoadOptions(batchSize: 1)))
        XCTAssertEqual(actions.count, 1)
        guard case .monitorSnapshot(let stamp, let snapshot)? = actions.first else { return XCTFail("Wrong action") }
        XCTAssertEqual(stamp, generation); XCTAssertEqual(snapshot.sortedEntries.count, 40)
    }
    func testCancelAtEntry() async throws {
        let entered = expectation(description: "boundary")
        let gate = T2EntryGate()
        let pair = AsyncThrowingStream<LoadEvent, Error>.makeStream()
        let fs = T2ControlledFS(root: root, entryGate: gate, entered: entered, enumerated: nil, stream: pair.stream)
        let loader = DirectoryLoadPipeline(fileSystem: fs)
        let old = await loader.load(.directory(root), generation: generation)
        await fulfillment(of: [entered], timeout: 2)
        await loader.cancel()
        await gate.release()
        pair.continuation.yield(.batch([FileEntry(url: root.appendingPathComponent("late"))])); pair.continuation.finish()
        let retired = await collect(old); XCTAssertTrue(retired.isEmpty)
        await loader.cancel()
    }
    func testSupersedeAtEntry() async throws {
        let entered = expectation(description: "boundary")
        let gate = T2EntryGate()
        let pair = AsyncThrowingStream<LoadEvent, Error>.makeStream()
        let fs = T2ControlledFS(root: root, entryGate: gate, entered: entered, enumerated: nil, stream: pair.stream)
        let loader = DirectoryLoadPipeline(fileSystem: fs)
        let old = await loader.load(.directory(root), generation: generation)
        await fulfillment(of: [entered], timeout: 2)
        let replacement = await loader.load(.recent, generation: Generation(rawValue: 74))
        await gate.release()
        pair.continuation.yield(.batch([FileEntry(url: root.appendingPathComponent("late"))])); pair.continuation.finish()
        let retired = await collect(old); XCTAssertTrue(retired.isEmpty)
        let newActions = await collect(replacement)
        guard case .loadFailed(let stamp, _)? = newActions.last else { return XCTFail("Replacement terminated by old worker") }
        XCTAssertEqual(stamp, Generation(rawValue: 74))
    }
    func testCancelAtEnumeration() async throws {
        let entered = expectation(description: "boundary")
        let gate = T2EntryGate()
        let pair = AsyncThrowingStream<LoadEvent, Error>.makeStream()
        let fs = T2ControlledFS(root: root, entryGate: nil, entered: nil, enumerated: entered, stream: pair.stream)
        let loader = DirectoryLoadPipeline(fileSystem: fs)
        let old = await loader.load(.directory(root), generation: generation)
        await fulfillment(of: [entered], timeout: 2)
        await loader.cancel()
        await gate.release()
        pair.continuation.yield(.batch([FileEntry(url: root.appendingPathComponent("late"))])); pair.continuation.finish()
        let retired = await collect(old); XCTAssertTrue(retired.isEmpty)
        await loader.cancel()
    }
    func testSupersedeAtEnumeration() async throws {
        let entered = expectation(description: "boundary")
        let gate = T2EntryGate()
        let pair = AsyncThrowingStream<LoadEvent, Error>.makeStream()
        let fs = T2ControlledFS(root: root, entryGate: nil, entered: nil, enumerated: entered, stream: pair.stream)
        let loader = DirectoryLoadPipeline(fileSystem: fs)
        let old = await loader.load(.directory(root), generation: generation)
        await fulfillment(of: [entered], timeout: 2)
        let replacement = await loader.load(.recent, generation: Generation(rawValue: 74))
        await gate.release()
        pair.continuation.yield(.batch([FileEntry(url: root.appendingPathComponent("late"))])); pair.continuation.finish()
        let retired = await collect(old); XCTAssertTrue(retired.isEmpty)
        let newActions = await collect(replacement)
        guard case .loadFailed(let stamp, _)? = newActions.last else { return XCTFail("Replacement terminated by old worker") }
        XCTAssertEqual(stamp, Generation(rawValue: 74))
    }
    func testCoalescerRootSurvivesStorm() async throws {
        let clock = FakeClock()
        let c = DirectoryReloadCoalescer(generation: generation, clock: clock)
        await c.receive(.rootChanged)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 { group.addTask { await c.receive(.changed(paths: ["/t2/\(i)"])) } }
        }
        clock.advance(by: 2); await c.flush(); await c.finish()
        let actions = await collect(c.actions)
        XCTAssertEqual(actions.count, 1)
        guard case .monitorEvent(let stamp, let event)? = actions.last else { return XCTFail("No coalesced event") }
        XCTAssertEqual(stamp, generation); XCTAssertEqual(event, .rootChanged)
    }
    func testCoalescerUnmountSurvivesStorm() async throws {
        let clock = FakeClock()
        let c = DirectoryReloadCoalescer(generation: generation, clock: clock)
        await c.receive(.volumeUnmounted)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 { group.addTask { await c.receive(.changed(paths: ["/t2/\(i)"])) } }
        }
        clock.advance(by: 2); await c.flush(); await c.finish()
        let actions = await collect(c.actions)
        XCTAssertEqual(actions.count, 1)
        guard case .monitorEvent(let stamp, let event)? = actions.last else { return XCTFail("No coalesced event") }
        XCTAssertEqual(stamp, generation); XCTAssertEqual(event, .volumeUnmounted)
    }
    func testCoalescerRescanSurvivesStorm() async throws {
        let clock = FakeClock()
        let c = DirectoryReloadCoalescer(generation: generation, clock: clock)
        await c.receive(.rescan)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 { group.addTask { await c.receive(.changed(paths: ["/t2/\(i)"])) } }
        }
        clock.advance(by: 2); await c.flush(); await c.finish()
        let actions = await collect(c.actions)
        XCTAssertEqual(actions.count, 1)
        guard case .monitorEvent(let stamp, let event)? = actions.last else { return XCTFail("No coalesced event") }
        XCTAssertEqual(stamp, generation); XCTAssertEqual(event, .rescan)
    }
    func testCoalescerFinishRejectsLaterEvents() async throws {
        let c = DirectoryReloadCoalescer(generation: generation, clock: FakeClock())
        await c.finish(); await c.receive(.rootChanged); await c.flush()
        let actions = await collect(c.actions); XCTAssertTrue(actions.isEmpty)
    }
    func testCoalescerAcknowledgementClearsRootPriority() async throws {
        let clock = FakeClock(); let c = DirectoryReloadCoalescer(generation: generation, clock: clock)
        await c.receive(.rootChanged); await c.acknowledgeRootValidation()
        await c.receive(.changed(paths: ["x"])); clock.advance(by: 2); await c.flush(); await c.finish()
        let actions = await collect(c.actions)
        guard case .monitorEvent(_, .rescan)? = actions.last else { return XCTFail("Acknowledged root remained sticky") }
    }
}
