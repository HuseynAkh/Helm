// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class K15CompletionCancellationTests: XCTestCase {
    /// F-016/B-052: cancellation after provider suspension rejects even a successful late result.
    func testCancelWhileProviderSuspended() async throws {
        let listing = K15GatedListing()
        let engine = PathCompletionEngine(listing: listing)
        let request = try XCTUnwrap(PathCompletionEngine.request(for: "/a/", currentDirectory: URL(fileURLWithPath: "/"),
            home: URL(fileURLWithPath: "/home"), showHidden: false, generation: Generation()))
        let task = Task { try await engine.complete(request) }
        await listing.waitUntilStarted()
        task.cancel()
        await listing.release()
        do { _ = try await task.value; XCTFail("B-052: cancelled completion returned rows") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    /// F-016: a pre-cancelled request does not enter the listing provider.
    func testCancelBeforeProviderStarts() async throws {
        let listing = K15CountingListing()
        let engine = PathCompletionEngine(listing: listing)
        let request = try XCTUnwrap(PathCompletionEngine.request(for: "/a/", currentDirectory: URL(fileURLWithPath: "/"),
            home: URL(fileURLWithPath: "/home"), showHidden: false, generation: Generation()))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.complete(request)
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let count = await listing.count; XCTAssertEqual(count, 0)
    }
}

private actor K15CountingListing: DirectoryListing {
    var count = 0
    func children(of url: URL, includeHidden: Bool) async throws -> [CompletionCandidate] { count += 1; return [] }
}

private actor K15GatedListing: DirectoryListing {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiter: CheckedContinuation<[CompletionCandidate], Never>?
    func children(of url: URL, includeHidden: Bool) async throws -> [CompletionCandidate] {
        return await withCheckedContinuation { continuation in
            resultWaiter = continuation
            started = true
            startWaiter?.resume(); startWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() {
        resultWaiter?.resume(returning: [CompletionCandidate(name: "late", url: URL(fileURLWithPath: "/a/late"), isDirectory: false)])
        resultWaiter = nil
    }
}
