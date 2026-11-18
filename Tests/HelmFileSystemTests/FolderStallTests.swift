import Foundation
import XCTest
@testable import HelmFileSystem

/// A read that stalls shuts only the folder it read, not its lane, so the rest of the disk carries on. The whole lane
/// still shuts when the disk itself looks stuck, and a stalled change still shuts it until it is reconciled (B-107).
final class FolderStallTests: XCTestCase {
    /// A call that waits until it is let go, and says when it has started and when it has gone.
    private final class Stall: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var entered = false, left = false
        func hold() {
            lock.lock(); entered = true; lock.unlock()
            gate.wait()
            lock.lock(); left = true; lock.unlock()
        }
        func release() { gate.signal() }
        var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        var hasLeft: Bool { lock.lock(); defer { lock.unlock() }; return left }
    }
    /// Whether a body ran, so a call refused at once can be told from one that ran and failed.
    private final class Ran: @unchecked Sendable {
        private let lock = NSLock()
        private var ran = false
        func mark() { lock.lock(); ran = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return ran }
    }
    /// A listing that keeps reporting progress, so it never counts as stalled, until it is told to stop.
    private final class Busy: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false, stopped = false
        func work(_ progress: () -> Void) {
            lock.lock(); started = true; lock.unlock()
            while !isStopped { Thread.sleep(forTimeInterval: 0.02); progress() }
        }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
        private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    /// How long a call may be silent before it counts as stalled. Short, so the tests are quick, and long enough that
    /// an ordinary call on a busy Mac is never taken for a stalled one.
    private static let stallAfter: TimeInterval = 0.15

    /// Waits for `condition`, which other threads decide, without holding one of the test's own.
    private func wait(for condition: @Sendable () async -> Bool) async throws -> Bool {
        for _ in 0..<1_000 {
            if await condition() { return true }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    /// A read held until `stall` is let go, which times out.
    private func stall(_ executor: IOExecutor, path: String?, on stall: Stall, line: UInt = #line) async {
        do { try await executor.runRead(path: path) { stall.hold() }; XCTFail("The read is waiting", line: line) }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut, line: line) }
    }

    /// The read fails as timed out without its body running.
    private func assertRefused(_ executor: IOExecutor, volume: String = "/", path: String?, _ message: String,
                               line: UInt = #line) async {
        let ran = Ran()
        do { try await executor.runRead(volume: volume, path: path) { ran.mark() }; XCTFail(message, line: line) }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut, message, line: line) }
        XCTAssertFalse(ran.value, "\(message): the body ran", line: line)
    }

    private func assertReads(_ executor: IOExecutor, volume: String = "/", path: String?, _ message: String,
                             line: UInt = #line) async {
        do {
            let value = try await executor.runRead(volume: volume, path: path) { 7 }
            XCTAssertEqual(value, 7, message, line: line)
        } catch { XCTFail("\(message): \(error)", line: line) }
    }

    private func assertTimedOut<T>(_ task: Task<T, Error>, _ message: String, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail(message, line: line) }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut, message, line: line) }
    }

    func testAStalledReadShutsOnlyItsFolderAndItOpensAgainWhenTheReadReturns() async throws {
        let executor = IOExecutor(timeout: Self.stallAfter)
        let held = Stall()
        defer { held.release() }
        await stall(executor, path: "/Users/me/Library/Thing", on: held)

        // That folder, and what is inside it however it is spelled, is refused at once.
        await assertRefused(executor, path: "/Users/me/Library/Thing", "the stalled folder")
        await assertRefused(executor, path: "/users/me/LIBRARY/thing/Inner/file.txt", "inside it, spelled otherwise")
        await assertRefused(executor, path: "/Users/me/Library/Thing/", "with a slash at the end")
        do {
            _ = try await executor.runReadWithProgress(path: "/Users/me/Library/Thing/Inner") { _ in XCTFail("The listing ran") }
            XCTFail("A listing inside it is refused too")
        } catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }

        // Everything else on the lane carries on: a name that only starts the same, the folder holding it, elsewhere,
        // a listing, and a read that names no path. Another lane never noticed.
        await assertReads(executor, path: "/Users/me/Library/Thing2", "a name that only starts the same")
        await assertReads(executor, path: "/Users/me/Library", "the folder holding it")
        await assertReads(executor, path: "/Users/me/Desktop", "elsewhere on the lane")
        await assertReads(executor, path: nil, "a read with no path")
        let listed = try await executor.runReadWithProgress(path: "/Users/me/Pictures") { progress in progress(); return 3 }
        XCTAssertEqual(listed, 3)
        await assertReads(executor, volume: "other", path: "/Users/me/Library/Thing", "another lane")

        // The read returns, and the folder opens again with nothing asked.
        held.release()
        let reopened = try await wait { (try? await executor.runRead(path: "/Users/me/Library/Thing/Inner") { 1 }) == 1 }
        XCTAssertTrue(reopened)
    }

    func testReadsStalledInTwoPlacesShutTheLaneUntilTheLastOfThemReturns() async throws {
        let executor = IOExecutor(timeout: Self.stallAfter)
        let first = Stall(), second = Stall()
        defer { first.release(); second.release() }
        await stall(executor, path: "/Users/me/Library/One", on: first)
        await assertReads(executor, path: "/Users/me/Desktop", "one stall shuts only its folder")
        await stall(executor, path: "/Users/me/Library/Two", on: second)

        // Two places, neither inside the other: the disk itself looks stuck, and the whole lane shuts.
        await assertRefused(executor, path: "/Users/me/Desktop", "elsewhere on the lane")
        await assertRefused(executor, path: nil, "a read with no path")
        await assertReads(executor, volume: "other", path: "/Users/me/Desktop", "another lane")

        // One returns. The other is still out, so the lane stays shut.
        first.release()
        let firstLeft = try await wait { first.hasLeft }
        XCTAssertTrue(firstLeft)
        try await Task.sleep(nanoseconds: 50_000_000)
        await assertRefused(executor, path: "/Users/me/Desktop", "the second read is still out")
        await assertRefused(executor, path: "/Users/me/Library/One", "the first folder too, while the lane is shut")

        // The last one returns, and the lane opens.
        second.release()
        let reopened = try await wait { (try? await executor.runRead(path: "/Users/me/Desktop") { 1 }) == 1 }
        XCTAssertTrue(reopened)
        await assertReads(executor, path: "/Users/me/Library/Two", "the second folder")
        await assertReads(executor, path: nil, "a read with no path")
    }

    func testAStalledReadThatNamesNoPathShutsTheLane() async throws {
        let executor = IOExecutor(timeout: Self.stallAfter)
        let held = Stall()
        defer { held.release() }
        await stall(executor, path: nil, on: held)
        // With no path, the read could have been of anything on the lane.
        await assertRefused(executor, path: "/Users/me/Desktop", "a read with a path")
        await assertRefused(executor, path: nil, "a read with none")
        await assertReads(executor, volume: "other", path: nil, "another lane")
        held.release()
        let reopened = try await wait { (try? await executor.runRead(path: "/Users/me/Desktop") { 1 }) == 1 }
        XCTAssertTrue(reopened)
    }

    func testStallsInsideOneAnotherCountAsOnePlace() async throws {
        // Wider than the other tests' limit: all three reads must be under way before the first times out.
        let executor = IOExecutor(timeout: 0.5)
        let outer = Stall(), inner = Stall(), again = Stall()
        defer { outer.release(); inner.release(); again.release() }
        let thing = "/Users/me/Library/Thing"
        let reads = [(thing, outer), (thing + "/Inner", inner), (thing, again)].map { path, stall in
            Task { try await executor.runRead(path: path) { stall.hold() } }
        }
        let underWay = try await wait { outer.hasEntered && inner.hasEntered && again.hasEntered }
        XCTAssertTrue(underWay, "three reads out at once")
        for read in reads { await assertTimedOut(read, "The read is waiting") }

        // A folder, a folder inside it and the same folder again are one place: the rest of the lane carries on.
        await assertReads(executor, path: "/Users/me/Desktop", "elsewhere on the lane")
        await assertRefused(executor, path: thing + "/Other", "inside the outer folder")

        // The outer folder's first read returns; its second still holds it.
        outer.release()
        let outerLeft = try await wait { outer.hasLeft }
        XCTAssertTrue(outerLeft)
        try await Task.sleep(nanoseconds: 50_000_000)
        await assertRefused(executor, path: thing + "/Other", "the same folder is still stalled")
        // Its second returns too: only the folder inside it is still stalled.
        again.release()
        let outerOpen = try await wait { (try? await executor.runRead(path: thing + "/Other") { 1 }) == 1 }
        XCTAssertTrue(outerOpen)
        await assertRefused(executor, path: thing + "/Inner/Deeper", "the inner folder is still stalled")
        inner.release()
        let innerOpen = try await wait { (try? await executor.runRead(path: thing + "/Inner/Deeper") { 1 }) == 1 }
        XCTAssertTrue(innerOpen)
    }

    func testStalledReadsHoldingEveryWorkerShutTheLane() async throws {
        let executor = IOExecutor(maxConcurrentOperations: 2, timeout: 0.5)
        let a = Stall(), b = Stall()
        defer { a.release(); b.release() }
        let reads = [a, b].map { stall in Task { try await executor.runRead(path: "/Users/me/Library/Thing") { stall.hold() } } }
        let underWay = try await wait { a.hasEntered && b.hasEntered }
        XCTAssertTrue(underWay)
        for read in reads { await assertTimedOut(read, "The read is waiting") }
        // Both of the lane's workers are held, so nothing else could run there. The lane shuts rather than leave
        // reads waiting for a worker with no time limit.
        await assertRefused(executor, path: "/Users/me/Desktop", "no worker is free")
        a.release(); b.release()
        let reopened = try await wait { (try? await executor.runRead(path: "/Users/me/Desktop") { 1 }) == 1 }
        XCTAssertTrue(reopened)
    }

    func testWhatWaitsToReadInTheStalledFolderIsTurnedAwayAndTheRestRunsWhenAWorkerIsFree() async throws {
        // A limit wide enough for the busy listing's progress, which reports every 20 ms.
        let executor = IOExecutor(maxConcurrentOperations: 2, timeout: 1)
        let held = Stall(), busy = Busy()
        defer { held.release(); busy.stop() }
        let stalled = Task { try await executor.runRead(path: "/Users/me/Library/Thing") { held.hold() } }
        let working = Task { try await executor.runReadWithProgress(path: "/Users/me/Pictures") { progress in busy.work(progress); return 1 } }
        let underWay = try await wait { held.hasEntered && busy.hasStarted }
        XCTAssertTrue(underWay)

        // Both workers are taken, so these wait their turn.
        let ranInside = Ran(), ranChange = Ran()
        let inside = Task { try await executor.runRead(path: "/Users/me/Library/Thing/Inner") { ranInside.mark() } }
        let change = Task { try await executor.run(volume: "/") { ranChange.mark() } }
        let elsewhere = Task { try await executor.runRead(path: "/Users/me/Desktop") { 2 } }
        await assertTimedOut(stalled, "The read is waiting")

        // The read inside the stalled folder, and the change, are turned away without running.
        await assertTimedOut(inside, "Inside the stalled folder")
        await assertTimedOut(change, "A change waits for no stalled read")
        XCTAssertFalse(ranInside.value)
        XCTAssertFalse(ranChange.value)
        // The read elsewhere is still waiting, and runs once the busy listing lets its worker go.
        busy.stop()
        let value = try await elsewhere.value
        XCTAssertEqual(value, 2)
        let listed = try await working.value
        XCTAssertEqual(listed, 1)
    }

    func testAChangeIsRefusedWhileAReadIsStalledOnItsLaneAndThatLeavesNothingToReconcile() async throws {
        let executor = IOExecutor(timeout: Self.stallAfter)
        let held = Stall()
        defer { held.release() }
        await stall(executor, path: "/Users/me/Library/Thing", on: held)
        // A change can't say where it lands, so it is refused while the read is out, as when the read shut the lane.
        let ran = Ran()
        do { try await executor.run(volume: "/") { ran.mark() }; XCTFail("Refused") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        XCTAssertFalse(ran.value)
        XCTAssertTrue(executor.reopenAll(), "a read leaves nothing to reconcile")
        XCTAssertFalse(executor.clearQuarantine(volume: "/"), "a timed-out call is still out")
        let other = try await executor.run(volume: "other") { 1 }
        XCTAssertEqual(other, 1)
        held.release()
        let changed = try await wait { (try? await executor.run(volume: "/") { 2 }) == 2 }
        XCTAssertTrue(changed, "the change runs once the read has returned")
    }

    func testAStalledChangeStillShutsItsWholeLaneUntilItIsReconciled() async throws {
        let executor = IOExecutor(timeout: Self.stallAfter)
        let held = Stall()
        defer { held.release() }
        do { try await executor.run(volume: "/") { held.hold() }; XCTFail("The change is waiting") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        await assertRefused(executor, path: "/Users/me/Desktop", "a read with a path")
        await assertRefused(executor, path: nil, "a read with none")
        XCTAssertFalse(executor.reopenAll(), "the change is still out")

        // The change returns. The lane stays shut until it is asked for: a late change may have landed.
        held.release()
        let left = try await wait { held.hasLeft }
        XCTAssertTrue(left)
        try await Task.sleep(nanoseconds: 50_000_000)
        await assertRefused(executor, path: "/Users/me/Desktop", "nothing reconciled it yet")
        let reopened = try await wait { executor.reopenAll() }
        XCTAssertTrue(reopened)
        await assertReads(executor, path: "/Users/me/Desktop", "reconciled")
    }

    func testPathsCompareFolderByFolderWithoutCase() {
        XCTAssertEqual(IOExecutor.spelling("/Users/Me/Library/"), "/users/me/library")
        XCTAssertEqual(IOExecutor.spelling("/"), "/")
        XCTAssertTrue(IOExecutor.isInside("/users/me/library", "/users/me/library"))
        XCTAssertTrue(IOExecutor.isInside("/users/me/library/thing", "/users/me/library"))
        XCTAssertFalse(IOExecutor.isInside("/users/me/library2", "/users/me/library"))
        XCTAssertFalse(IOExecutor.isInside("/users/me", "/users/me/library"))
        XCTAssertTrue(IOExecutor.isInside("/users", "/"), "the disk's top holds everything")
    }
}
