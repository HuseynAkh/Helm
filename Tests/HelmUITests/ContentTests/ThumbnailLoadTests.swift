#if os(macOS)
import AppKit
import Foundation
import XCTest
import HelmCore
@testable import HelmUI

/// Stands in for Quick Look: it keeps each request and answers only when a test says, in the order the test says.
@MainActor private final class ScriptedPreviews: PreviewSource {
    final class Request {
        let update: @MainActor (PreviewStep) -> Void
        var stopped = false
        init(update: @escaping @MainActor (PreviewStep) -> Void) { self.update = update }
    }
    private(set) var requests: [Request] = []
    func start(_ url: URL, size: NSSize, scale: CGFloat, iconMode: Bool,
               update: @escaping @MainActor (PreviewStep) -> Void) -> () -> Void {
        let request = Request(update: update)
        requests.append(request)
        return { request.stopped = true }
    }
}

/// Thumbnails in the grid and the list: a picture whose cell comes and goes while Quick Look works still gets its
/// thumbnail, and a picture no cell wants any more stops being worked on.
@MainActor final class ThumbnailLoadTests: XCTestCase {
    private let picture = FileEntry(url: URL(fileURLWithPath: "/tmp/helm-fixture/Pictures/Sunset.jpg"), size: 120_000,
                                    modificationDate: Date(timeIntervalSince1970: 1_800_000_000),
                                    contentTypeIdentifier: "public.jpeg")
    private let thumbnail = NSImage(size: NSSize(width: 96, height: 64))
    private var previews: ScriptedPreviews!
    private var cache: IconCache!

    override func setUp() {
        super.setUp()
        previews = ScriptedPreviews()
        cache = IconCache(limit: 50, previewLimit: 10, previewSource: previews)
    }

    private func load(_ shown: @escaping (NSImage) -> Void) -> IconCache.Ticket? {
        cache.load(for: picture, points: 96, scale: 2, previews: true, deliver: shown)
    }
    /// Runs the main queue until `condition` holds, for the file's icon, which comes from another queue.
    private func settle(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), "nothing arrived")
    }
    /// Lets the main queue finish this turn, as the app's run loop does between one event and the next.
    private func nextTurn() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    /// What the grid did when a folder's second listing came in: the item showing a picture was reused first, which
    /// stopped the picture's request, and a later item asked for the picture again. The first request's late answer,
    /// that it was stopped, used to end the second load too, so its thumbnail never reached the new item.
    func testAStoppedRequestNeverEndsTheLoadThatTookItsPlace() {
        var first: [NSImage] = []
        let ticket = load { first.append($0) }
        settle { !first.isEmpty }
        cache.cancel(ticket)
        nextTurn()
        XCTAssertTrue(previews.requests[0].stopped, "a picture no cell wants stops being worked on")
        var second: [NSImage] = []
        XCTAssertNotNil(load { second.append($0) })
        XCTAssertEqual(previews.requests.count, 2)
        guard previews.requests.count == 2 else { return }
        previews.requests[0].update(.stopped)
        previews.requests[1].update(.full(thumbnail))
        XCTAssertTrue(second.last === thumbnail, "the new item shows the thumbnail")
        XCTAssertEqual(cache.describe(second.last, for: picture, points: 96, scale: 2), "thumbnail")
        XCTAssertEqual(cache.loadsForTesting, 0)
    }

    /// A reload puts every file back in an item within one turn of the run loop. A picture that only moved to another
    /// item keeps the request already under way, so nothing is stopped and asked for again.
    func testAReloadThatMovesAPictureKeepsItsRequest() {
        let ticket = load { _ in }
        cache.cancel(ticket)
        var moved: [NSImage] = []
        XCTAssertNotNil(load { moved.append($0) })
        nextTurn()
        XCTAssertEqual(previews.requests.count, 1)
        XCTAssertFalse(previews.requests[0].stopped)
        previews.requests[0].update(.full(thumbnail))
        XCTAssertTrue(moved.last === thumbnail)
    }

    /// A request stopped before Quick Look answered says nothing about the file, so the icon isn't taken as all
    /// there is: the next item to show the picture asks again, and gets its thumbnail.
    func testAStoppedRequestIsNotAnAnswer() {
        var shown: [NSImage] = []
        _ = load { shown.append($0) }
        settle { !shown.isEmpty }
        previews.requests[0].update(.stopped)
        XCTAssertEqual(cache.loadsForTesting, 0)
        var again: [NSImage] = []
        XCTAssertNotNil(load { again.append($0) }, "it asks again")
        XCTAssertEqual(previews.requests.count, 2)
        guard previews.requests.count == 2 else { return }
        previews.requests[1].update(.full(thumbnail))
        XCTAssertTrue(again.last === thumbnail)
    }

    /// When Quick Look answers that it can't make a preview, the file's icon is the answer, and nobody asks again.
    func testNoPreviewIsAnAnswer() {
        var shown: [NSImage] = []
        _ = load { shown.append($0) }
        settle { !shown.isEmpty }
        previews.requests[0].update(.full(nil))
        var again: [NSImage] = []
        XCTAssertNil(load { again.append($0) })
        XCTAssertTrue(again.first === shown.last)
        XCTAssertEqual(cache.describe(again.first, for: picture, points: 96, scale: 2), "file icon")
        XCTAssertEqual(previews.requests.count, 1)
    }

    /// Quick Look can finish just as a request is stopped. That thumbnail is still the file's, so it's kept, and the
    /// next item to show the picture gets it at once without asking again.
    func testAThumbnailThatArrivesAfterTheStopIsKept() {
        let ticket = load { _ in }
        cache.cancel(ticket)
        nextTurn()
        previews.requests[0].update(.full(thumbnail))
        var later: [NSImage] = []
        XCTAssertNil(load { later.append($0) })
        XCTAssertTrue(later.first === thumbnail)
        XCTAssertEqual(previews.requests.count, 1)
    }
}
#endif
