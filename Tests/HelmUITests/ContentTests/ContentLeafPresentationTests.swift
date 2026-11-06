// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmUI

final class ContentLeafPresentationTests: XCTestCase {
    func testCloudBadgesDoNotInventUnknownDownloadState() {
        XCTAssertNil(ContentLeafPresentation.cloudBadge(.local))
        XCTAssertNil(ContentLeafPresentation.cloudBadge(.unknown))
        XCTAssertEqual(ContentLeafPresentation.cloudBadge(.evicted),
                       ContentBadge(symbol: "icloud.and.arrow.down", label: "Available in cloud"))
        XCTAssertEqual(ContentLeafPresentation.cloudBadge(.downloading),
                       ContentBadge(symbol: "arrow.down.circle", label: "Downloading"))
    }
    func testAllPlannerFeedbackHasDistinctSpokenAndVisualPresentation() {
        let values: [DropFeedback] = [.copy, .move, .alias, .trash, .forbidden]
        let badges: [ContentBadge] = values.map(ContentLeafPresentation.dragBadge)
        XCTAssertEqual(badges.map(\.label), ["Copy", "Move", "Create Alias", "Move to Trash", "Drop Not Allowed"])
        XCTAssertEqual(Set(badges.map(\.symbol)).count, values.count)
        XCTAssertTrue(badges.allSatisfy { !$0.symbol.isEmpty })
    }
    func testHiddenAndCutDimmingCompose() {
        XCTAssertEqual(ContentLeafPresentation.opacity(isHidden: false, isCut: false), 1)
        XCTAssertEqual(ContentLeafPresentation.opacity(isHidden: true, isCut: false), 0.5)
        XCTAssertEqual(ContentLeafPresentation.opacity(isHidden: false, isCut: true), 0.5)
        XCTAssertEqual(ContentLeafPresentation.opacity(isHidden: true, isCut: true), 0.25)
    }
    func testMarqueeNormalizesReverseDragAndClipsToGrid() {
        let geometry = GridGeometry(itemCount: 10, availableWidth: 320)
        XCTAssertEqual(ContentLeafPresentation.rubberBand(CGRect(x: 100, y: 80, width: -60, height: -40),
                                                         geometry: geometry),
                       CGRect(x: 40, y: 40, width: 60, height: 40))
        XCTAssertEqual(ContentLeafPresentation.rubberBand(CGRect(x: -20, y: -10, width: 400, height: 50),
                                                         geometry: geometry),
                       CGRect(x: 0, y: 0, width: 320, height: 40))
        let tall = CGRect(x: 0, y: 0, width: 320, height: 100_000)
        XCTAssertEqual(ContentLeafPresentation.rubberBand(tall, geometry: geometry)?.height, geometry.contentHeight)
    }
    func testMarqueeRejectsEmptyOutsideAndNonfiniteInput() {
        let geometry = GridGeometry(itemCount: 2, availableWidth: 320)
        let invalid: [CGRect?] = [nil, .zero, CGRect(x: 400, y: 0, width: 10, height: 10),
            CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)]
        for rect in invalid { XCTAssertNil(ContentLeafPresentation.rubberBand(rect, geometry: geometry)) }
        XCTAssertNil(ContentLeafPresentation.rubberBand(CGRect(x: 0, y: 0, width: 10, height: 10),
                                                       geometry: GridGeometry(itemCount: 0, availableWidth: 0)))
    }
    func testRejectedProposalsAndMissingProposalsNeverHighlight() {
        let destination = DropDestination(location: .directory(URL(fileURLWithPath: "/target")))
        let rejected = FileDropProposal(sources: [], destination: destination, result: .failure(.emptySources))
        XCTAssertFalse(ContentLeafPresentation.isHighlighted(.background, proposal: rejected))
        XCTAssertFalse(ContentLeafPresentation.isHighlighted(.none, proposal: rejected))
        XCTAssertFalse(ContentLeafPresentation.isHighlighted(.background, proposal: nil))
    }
    func testAcceptedProposalHighlightsOnlyItsStableTarget() {
        let id = ItemID(url: URL(fileURLWithPath: "/target"))
        let other = ItemID(url: URL(fileURLWithPath: "/other"))
        let destination = DropDestination(location: .directory(URL(fileURLWithPath: "/target")), highlight: .row(id))
        let accepted = FileDropProposal(sources: [], destination: destination, result: .success(.copy))
        XCTAssertTrue(ContentLeafPresentation.isHighlighted(.row(id), proposal: accepted))
        XCTAssertFalse(ContentLeafPresentation.isHighlighted(.row(other), proposal: accepted))
        XCTAssertFalse(ContentLeafPresentation.isHighlighted(.background, proposal: accepted))
        XCTAssertFalse(ContentLeafPresentation.isHighlighted(.none, proposal: accepted))
        let background = FileDropProposal(sources: [], destination: DropDestination(location: destination.location),
                                      result: .success(.move))
        XCTAssertTrue(ContentLeafPresentation.isHighlighted(.background, proposal: background))
    }
}
