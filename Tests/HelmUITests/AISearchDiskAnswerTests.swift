#if os(macOS)
import Foundation
import XCTest
import HelmCore
@testable import HelmUI

/// AI search says the disk didn't answer only when it found nothing because of that, never in place of a count.
@MainActor final class AISearchDiskAnswerTests: XCTestCase {
    func testNothingFoundBecauseTheDiskDidntAnswerIsSaidSo() {
        let here = StorageFacts.thisMac
        var stuck = StorageFacts.thisMac
        stuck.isResponding = false
        XCTAssertTrue(AISearchRunner.diskDidntAnswer(found: 0, walkTimedOut: true, readsTimedOut: false, place: here), "the walk")
        XCTAssertTrue(AISearchRunner.diskDidntAnswer(found: 0, walkTimedOut: false, readsTimedOut: true, place: here),
                      "Spotlight's hits")
        XCTAssertTrue(AISearchRunner.diskDidntAnswer(found: 0, walkTimedOut: false, readsTimedOut: false, place: stuck),
                      "the place searched")
        XCTAssertFalse(AISearchRunner.diskDidntAnswer(found: 0, walkTimedOut: false, readsTimedOut: false, place: here),
                       "nothing timed out: no matches is the answer")
        XCTAssertFalse(AISearchRunner.diskDidntAnswer(found: 3, walkTimedOut: true, readsTimedOut: true, place: stuck),
                       "what was found is counted")
    }
}
#endif
