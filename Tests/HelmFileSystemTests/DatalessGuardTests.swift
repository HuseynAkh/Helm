import Foundation
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmFileSystem

/// "Downloads off": a task is marked, and the I/O queue turns the mark into macOS's per-thread switch for exactly as
/// long as one of that task's bodies runs. No test here can hold a file that is in a cloud only, so they show the
/// switch itself: on inside a marked body, back afterwards, and never touched for anything else.
final class DatalessGuardTests: XCTestCase {
    /// What bodies saw, gathered from whichever threads ran them.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func add(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
        /// Everything added since the last call.
        func take() -> [Bool] {
            lock.lock(); defer { lock.unlock() }
            let taken = values
            values.removeAll()
            return taken
        }
    }

    // MARK: The mark on a task

    func testTheMarkIsSetOnlyInsideOff() async throws {
        XCTAssertFalse(DatalessGuard.isOff)
        let inside = await DatalessGuard.off { DatalessGuard.isOff }
        XCTAssertTrue(inside)
        XCTAssertFalse(DatalessGuard.isOff)
        // What the work returns and what it throws come straight through.
        let value = try await DatalessGuard.off { () throws -> Int in 7 }
        XCTAssertEqual(value, 7)
        do {
            try await DatalessGuard.off { throw FileSystemError.notFound }
            XCTFail("The error was dropped")
        } catch { XCTAssertEqual(error as? FileSystemError, .notFound) }
        XCTAssertFalse(DatalessGuard.isOff)
    }

    func testOffIfMarksOnlyWhenWanted() async {
        let wanted = await DatalessGuard.off(if: true) { DatalessGuard.isOff }
        let unwanted = await DatalessGuard.off(if: false) { DatalessGuard.isOff }
        XCTAssertTrue(wanted)
        XCTAssertFalse(unwanted)
        // Not wanting it never turns downloads back on inside work that already has them off.
        let nested = await DatalessGuard.off { await DatalessGuard.off(if: false) { DatalessGuard.isOff } }
        XCTAssertTrue(nested)
        XCTAssertFalse(DatalessGuard.isOff)
    }

    func testTasksStartedInsideCarryTheMarkAndDetachedOnesDoNot() async {
        let seen = await DatalessGuard.off { () -> [Bool] in
            async let child = DatalessGuard.isOff
            let started = await Task { DatalessGuard.isOff }.value
            let detached = await Task.detached { DatalessGuard.isOff }.value
            return [await child, started, detached]
        }
        XCTAssertEqual(seen, [true, true, false])
    }

    // MARK: What a refused read is called

    func testAReadRefusedForWantOfADownloadIsNotDownloaded() {
        // macOS answers EDEADLK when a read needs a download and the thread has downloads off.
        let refused = NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK))
        XCTAssertEqual(FileSystemError.mapping(refused), .notDownloaded)
        // Foundation wraps the same refusal in an error of its own.
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [NSUnderlyingErrorKey: refused])
        XCTAssertEqual(FileSystemError.mapping(wrapped), .notDownloaded)
        XCTAssertEqual(FileSystemError.mapping(FileSystemError.notDownloaded), .notDownloaded)
        // It is one of the `.other` values, so nothing that switches over the error's cases changes, and it is no
        // other failure.
        guard case .other = FileSystemError.notDownloaded else { return XCTFail("notDownloaded became a case of its own") }
        for other: FileSystemError in [.notFound, .permissionDenied, .timedOut, .unsupported, .other("No space")] {
            XCTAssertNotEqual(other, .notDownloaded)
        }
        // The neighbouring answers are as they were.
        XCTAssertEqual(FileSystemError.mapping(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))), .notFound)
        XCTAssertEqual(FileSystemError.mapping(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))), .permissionDenied)
        XCTAssertEqual(FileSystemError.mapping(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), .other("No space"))
    }

    // MARK: The switch on a thread

    #if canImport(Darwin)
    func testWithDownloadsOffSwitchesTheCallingThreadAndPutsItBack() {
        XCTAssertFalse(DatalessGuard.threadPolicyIsOffForTesting)
        let inside = DatalessGuard.withDownloadsOff { DatalessGuard.threadPolicyIsOffForTesting }
        XCTAssertTrue(inside)
        XCTAssertFalse(DatalessGuard.threadPolicyIsOffForTesting)
        // An inner call leaves the switch to the outer one, which still has it off afterwards.
        let nested = DatalessGuard.withDownloadsOff { () -> [Bool] in
            let inner = DatalessGuard.withDownloadsOff { DatalessGuard.threadPolicyIsOffForTesting }
            return [inner, DatalessGuard.threadPolicyIsOffForTesting]
        }
        XCTAssertEqual(nested, [true, true])
        XCTAssertFalse(DatalessGuard.threadPolicyIsOffForTesting)
        // A body that throws puts it back too.
        XCTAssertThrowsError(try DatalessGuard.withDownloadsOff { throw FileSystemError.notDownloaded })
        XCTAssertFalse(DatalessGuard.threadPolicyIsOffForTesting)
    }

    func testAThreadGetsBackTheSettingItHad() {
        // A thread that asked for downloads by name is given that back, not the default.
        let done = DispatchSemaphore(value: 0)
        let seen = Seen()
        let thread = Thread {
            let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, scope = IOPOL_SCOPE_THREAD
            seen.add(setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_ON) == 0)
            seen.add(DatalessGuard.withDownloadsOff { DatalessGuard.threadPolicyIsOffForTesting })
            seen.add(getiopolicy_np(policy, scope) == IOPOL_MATERIALIZE_DATALESS_FILES_ON)
            done.signal()
        }
        thread.start()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(seen.take(), [true, true, true])
        // Another thread's switch is its own.
        XCTAssertFalse(DatalessGuard.threadPolicyIsOffForTesting)
    }

    // MARK: The I/O queue

    func testABodyRunByTheExecutorHasDownloadsOffOnlyInsideTheMark() async throws {
        let executor = IOExecutor(maxConcurrentOperations: 1)
        let isOff: @Sendable () -> Bool = { DatalessGuard.threadPolicyIsOffForTesting }
        let outside = try await executor.runRead(volume: "v", isOff)
        XCTAssertFalse(outside, "An unmarked body was touched")
        // Every way into the executor: a change, a read, each with and without progress, one disk and two.
        let inside = try await DatalessGuard.off { () -> [Bool] in
            [try await executor.run(volume: "v", isOff),
             try await executor.runRead(volume: "v", isOff),
             try await executor.runReadWithProgress(volume: "v") { _ in isOff() },
             try await executor.runWithProgress(volumes: ["v", "w"]) { _ in isOff() },
             try await executor.run(volumes: ["v", "w"], isOff)]
        }
        XCTAssertEqual(inside, [true, true, true, true, true])
        // A body that fails inside the mark gives its error as it is.
        do {
            _ = try await DatalessGuard.off {
                try await executor.runRead(volume: "v") { () throws -> Bool in throw FileSystemError.notDownloaded }
            }
            XCTFail("The error was dropped")
        } catch { XCTAssertEqual(error as? FileSystemError, .notDownloaded) }
        // The queue's threads are used again, and each is as it was once its body returned.
        for _ in 0..<50 {
            let later = try await executor.runRead(volume: "v", isOff)
            XCTAssertFalse(later, "A queue thread kept downloads off")
            let change = try await executor.run(volume: "w", isOff)
            XCTAssertFalse(change, "A queue thread kept downloads off")
        }
        XCTAssertFalse(DatalessGuard.isOff)
    }

    func testTheMarkTravelsWithTheBodyNotWithTheQueue() async throws {
        // One body at a time: the next two wait in the queue, and run later on a thread of the queue's choosing.
        let executor = IOExecutor(maxConcurrentOperations: 1)
        let entered = Seen(), gate = DispatchSemaphore(value: 0)
        let first = Task {
            try await executor.runRead(volume: "v") { () -> Bool in
                entered.add(true); gate.wait()
                return DatalessGuard.threadPolicyIsOffForTesting
            }
        }
        var waits = 0
        while entered.take().isEmpty, waits < 1_000 { try await Task.sleep(nanoseconds: 5_000_000); waits += 1 }
        let marked = Task {
            try await DatalessGuard.off { try await executor.runRead(volume: "v") { DatalessGuard.threadPolicyIsOffForTesting } }
        }
        let plain = Task { try await executor.runRead(volume: "v") { DatalessGuard.threadPolicyIsOffForTesting } }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.signal()
        let (firstSaw, markedSaw, plainSaw) = (try await first.value, try await marked.value, try await plain.value)
        XCTAssertFalse(firstSaw)
        XCTAssertTrue(markedSaw, "The mark was lost while the body waited in the queue")
        XCTAssertFalse(plainSaw, "A body queued beside a marked one was touched")
    }

    /// Seen through the two seams a LiveFileSystem has: what reads an item's details, and the Trash. The calls with
    /// neither (the plain creates, copies, moves and removes, and the questions about a volume) hand their bodies
    /// to the same executor, and the executor's own test above covers every way into it.
    func testLiveFileSystemCallsRunWithDownloadsOffInsideTheMark() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let file = temp.url.appendingPathComponent("a.txt")
        let copy = temp.url.appendingPathComponent("copy.txt"), moved = temp.url.appendingPathComponent("moved.txt")
        try Data("x".utf8).write(to: file)
        let seen = Seen()
        let reads = LiveFileSystem(readMetadata: { url, resolve, volume in
            seen.add(DatalessGuard.threadPolicyIsOffForTesting)
            return try MetadataReader().read(url, resolveSymlinkTargets: resolve, volumeIdentifier: volume)
        })
        let changes = LiveFileSystem(trash: { _ in seen.add(DatalessGuard.threadPolicyIsOffForTesting); return nil })

        _ = try await reads.entry(at: file)
        for try await _ in reads.enumerate(temp.url) {}
        _ = try await changes.trashItem(at: file)
        XCTAssertEqual(seen.take(), [false, false, false])

        try await DatalessGuard.off {
            // One read each: the item, the folder's one child for the listing and again for its names, then the
            // item and the folder asked about.
            _ = try await reads.entry(at: file)
            // A listing reads on a task of its own, which carries the mark with it.
            for try await _ in reads.enumerate(temp.url) {}
            _ = try await reads.childNames(of: temp.url)
            let exists = await reads.exists(file)
            let isFolder = await reads.isDirectory(temp.url)
            XCTAssertTrue(exists)
            XCTAssertTrue(isFolder)
            XCTAssertEqual(seen.take(), [true, true, true, true, true])

            // The conditional changes that Apply and Undo go through. Each reads its source again on the queue's
            // thread before it changes anything, so there is one read for the evidence and one for the change.
            let evidence = try await reads.mutationPrecondition(at: file)
            _ = try await reads.mutate(.copy(to: copy), source: file, requiring: evidence)
            let copied = try await reads.mutationPrecondition(at: copy)
            _ = try await reads.mutate(.move(to: moved), source: copy, requiring: copied)
            XCTAssertEqual(seen.take(), [true, true, true, true])

            // A size walks on a task of its own, and lists on another: the folder, its two children as listed,
            // then each child.
            for try await _ in reads.sizeOfTree(at: temp.url) {}
            XCTAssertEqual(seen.take(), [true, true, true, true, true])

            // The Trash, plainly and as a conditional change. The stand-in keeps the item where it is.
            _ = try await changes.trashItem(at: file)
            let kept = try await changes.mutationPrecondition(at: file)
            _ = try await changes.mutate(.trash, source: file, requiring: kept)
            XCTAssertEqual(seen.take(), [true, true])
        }
        let wasMoved = FileManager.default.fileExists(atPath: moved.path) && !FileManager.default.fileExists(atPath: copy.path)
        XCTAssertTrue(wasMoved, "The changes inside the mark didn't happen")

        _ = try await reads.entry(at: file)
        XCTAssertEqual(seen.take(), [false])
    }

    func testAListingOrSizeCarriesTheMarkOfTheTaskThatMadeIt() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        try Data("x".utf8).write(to: temp.url.appendingPathComponent("a.txt"))
        let seen = Seen()
        let reads = LiveFileSystem(readMetadata: { url, resolve, volume in
            seen.add(DatalessGuard.threadPolicyIsOffForTesting)
            return try MetadataReader().read(url, resolveSymlinkTargets: resolve, volumeIdentifier: volume)
        })
        // A listing reads its one child. A size reads the folder, lists it, then reads the child: four reads.

        // Made outside and read inside: the stream's task started unmarked, so downloads stay on.
        let listedOutside = reads.enumerate(temp.url), sizedOutside = reads.sizeOfTree(at: temp.url)
        try await DatalessGuard.off {
            for try await _ in listedOutside {}
            for try await _ in sizedOutside {}
        }
        XCTAssertEqual(seen.take(), [false, false, false, false], "A stream made outside the mark picked it up from its reader")

        // Made inside and read outside: downloads are off, though the reader isn't marked.
        let (listedInside, sizedInside) = await DatalessGuard.off { (reads.enumerate(temp.url), reads.sizeOfTree(at: temp.url)) }
        XCTAssertFalse(DatalessGuard.isOff)
        for try await _ in listedInside {}
        for try await _ in sizedInside {}
        XCTAssertEqual(seen.take(), [true, true, true, true], "A stream made inside the mark lost it")
    }
    #endif
}
