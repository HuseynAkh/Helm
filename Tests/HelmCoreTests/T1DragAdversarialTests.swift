// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmTestKit
final class T1DragAdversarialTests: XCTestCase {
    private let a = ItemID(rawValue: "/a")
    private let b = ItemID(rawValue: "/b")
    private func item(_ path: String, volume: String? = "v") -> DraggedItem { DraggedItem(url: URL(fileURLWithPath: path), volumeID: volume) }
    private var destination: DropDestination { DropDestination(location: .directory(URL(fileURLWithPath: "/out")), volumeID: "v") }

    func testAutoScrollSymmetry()  {
        let model = DragAutoScrollModel(edgeExtent: 40, maximumSpeed: 800)
        for x in stride(from: 0.0, through: 200.0, by: 0.5) {
            XCTAssertEqual(model.velocity(position: x, viewportExtent: 200), -model.velocity(position: 200 - x, viewportExtent: 200), accuracy: 0.000001)
        }
        XCTAssertEqual(model.velocity(position: 0, viewportExtent: 200), -800)
    }
    func testAutoScrollSmallViewport()  {
        let model = DragAutoScrollModel(edgeExtent: 100, maximumSpeed: 50)
        XCTAssertEqual(model.velocity(position: 5, viewportExtent: 10), 0)
        XCTAssertEqual(model.velocity(position: 10, viewportExtent: 10), 50)
    }
    func testAutoScrollInvalidInputs()  {
        let model = DragAutoScrollModel()
        for x in [-1.0, 101, .nan, .infinity] { XCTAssertEqual(model.velocity(position: x, viewportExtent: 100), 0) }
        XCTAssertEqual(DragAutoScrollModel(edgeExtent: .nan).velocity(position: 0, viewportExtent: 100), 0)
    }
    func testSpringExactDeadlineAndOnce()  {
        let clock = FakeClock(); var model = SpringLoadingModel(clock: clock, delay: 1)
        model.beginHover(id: a, isDirectory: true); clock.advance(by: 0.5)
        model.beginHover(id: a, isDirectory: true); XCTAssertNil(model.poll())
        clock.advance(by: 0.5); XCTAssertEqual(model.poll(), a); XCTAssertNil(model.poll(openImmediately: true))
    }
    func testSpringChangedHoverResetsDeadline()  {
        let clock = FakeClock(); var model = SpringLoadingModel(clock: clock, delay: 1)
        model.beginHover(id: a, isDirectory: true); clock.advance(by: 0.75)
        model.beginHover(id: b, isDirectory: true); clock.advance(by: 0.75); XCTAssertNil(model.poll())
        clock.advance(by: 0.25); XCTAssertEqual(model.poll(), b)
    }
    func testSpringCancelAndReentry()  {
        let clock = FakeClock(); var model = SpringLoadingModel(clock: clock, delay: 0)
        model.beginHover(id: a, isDirectory: true); model.cancel(); XCTAssertNil(model.poll(openImmediately: true))
        model.beginHover(id: a, isDirectory: true); XCTAssertEqual(model.poll(), a)
    }
    func testSpringPackageAndFileRejection()  {
        var model = SpringLoadingModel(clock: FakeClock(), delay: 0)
        model.beginHover(id: a, isDirectory: true, isPackage: true); XCTAssertNil(model.poll())
        model.beginHover(id: a, isDirectory: true, isPackage: true, allowsPackageContents: true); XCTAssertEqual(model.poll(), a)
        model.beginHover(id: b, isDirectory: false); XCTAssertNil(model.hoveredID)
    }
    func testTabExactMidpoints()  {
        XCTAssertEqual(TabDragModel.insertionIndex(x: 49.999, widths: [100, 200]), 0)
        XCTAssertEqual(TabDragModel.insertionIndex(x: 50, widths: [100, 200]), 1)
        XCTAssertEqual(TabDragModel.insertionIndex(x: 200, widths: [100, 200]), 2)
    }
    func testTabInvalidWidths()  {
        for width in [0.0, -1, .infinity, .nan] { XCTAssertNil(TabDragModel.insertionIndex(x: 1, widths: [100, width])) }
        XCTAssertNil(TabDragModel.insertionIndex(x: .nan, widths: []))
        XCTAssertEqual(TabDragModel.insertionIndex(x: 0, widths: []), 0)
    }
    func testTabReorderExhaustiveOracle()  {
        for count in 1...15 { for source in 0..<count { for slot in 0...count {
            var expected = Array(0..<count); expected.remove(at: source)
            let target = slot > source ? slot - 1 : slot; expected.insert(source, at: target)
            let result = TabDragModel.reorderIndex(sourceIndex: source, insertionIndex: slot, count: count)
            if expected == Array(0..<count) { XCTAssertNil(result) } else { XCTAssertEqual(result, target) }
        } } }
    }
    func testTabSingleCannotDetach()  {
        XCTAssertEqual(TabDragModel.intent(sourceIndex: 0, sourceCount: 1, destinationWidths: nil, destinationX: 0, sameWindow: true, distanceOutsideStrip: 100), .none)
        XCTAssertEqual(TabDragModel.intent(sourceIndex: 0, sourceCount: 2, destinationWidths: nil, destinationX: 0, sameWindow: true, distanceOutsideStrip: 40), .detach)
    }
    func testSourceUsesVisibleOrderAndDeduplicates()  {
        let items = [item("/b"), item("/a"), item("/b")]
        let model = DragSourceModel(clickedID: a, selectedIDs: [a, b], orderedItems: items)
        XCTAssertEqual(model.items.map(\.id), [b, a]); XCTAssertEqual(model.itemCountBadge, 2); XCTAssertEqual(model.imageCount, 2)
    }
    func testSourceUnselectedClickIsSingle()  {
        let model = DragSourceModel(clickedID: a, selectedIDs: [b], orderedItems: [item("/b"), item("/a")], maximumImages: -1)
        XCTAssertEqual(model.items.map(\.id), [a]); XCTAssertNil(model.itemCountBadge); XCTAssertEqual(model.imageCount, 0)
    }
    func testSourceMissingClickedItemIsEmpty()  {
        let model = DragSourceModel(clickedID: a, selectedIDs: [a, b], orderedItems: [item("/b")])
        XCTAssertTrue(model.items.isEmpty); XCTAssertNil(model.itemCountBadge)
    }
    func testDragThresholdEuclideanBoundary()  {
        XCTAssertTrue(DragSourceModel.exceedsThreshold(deltaX: 3, deltaY: 4, threshold: 5))
        XCTAssertFalse(DragSourceModel.exceedsThreshold(deltaX: 3, deltaY: 4, threshold: 5.001))
        XCTAssertFalse(DragSourceModel.exceedsThreshold(deltaX: 0, deltaY: 0, threshold: 0))
        XCTAssertFalse(DragSourceModel.exceedsThreshold(deltaX: .nan, deltaY: 4))
    }
    func testDropEmptySourcesForbidden()  {
        let proposal = DropPlanner.proposal(sources: [], destination: destination)
        XCTAssertEqual(proposal.rejection, .emptySources); XCTAssertEqual(proposal.feedback, .forbidden); XCTAssertEqual(proposal.highlight, .none)
    }
    func testDropDefaultVolumePolicy()  {
        XCTAssertEqual(DropPlanner.proposal(sources: [item("/a")], destination: destination).operation, .move)
        XCTAssertEqual(DropPlanner.proposal(sources: [item("/a", volume: "other")], destination: destination).operation, .copy)
        XCTAssertEqual(DropPlanner.proposal(sources: [item("/a", volume: nil)], destination: destination).operation, .copy)
    }
    func testDropModifierOverrides()  {
        XCTAssertEqual(DropPlanner.proposal(sources: [item("/a")], destination: destination, modifiers: .option).operation, .copy)
        XCTAssertEqual(DropPlanner.proposal(sources: [item("/a")], destination: destination, modifiers: [.command, .option], allowedOperations: [.copy, .move, .alias]).operation, .alias)
        // OK1-9: alias is not in the default mask, so the same modifiers are refused when the source does not allow it
        XCTAssertNil(DropPlanner.proposal(sources: [item("/a")], destination: destination, modifiers: [.command, .option]).operation)
        XCTAssertEqual(DropPlanner.proposal(sources: [item("/a")], destination: destination, allowedOperations: []).rejection, .unsupportedOperation)
    }
    func testDropPrefixSiblingIsNotDescendant()  {
        let target = DropDestination(location: .directory(URL(fileURLWithPath: "/ab")), volumeID: "v")
        XCTAssertEqual(DropPlanner.proposal(sources: [item("/a")], destination: target).operation, .move)
        let child = DropDestination(location: .directory(URL(fileURLWithPath: "/a/b")))
        XCTAssertEqual(DropPlanner.proposal(sources: [item("/a")], destination: child).rejection, .intoDescendant)
    }
    func testDropOverlapOrderIndependent()  {
        for sources in [[item("/a"), item("/a/b")], [item("/a/b"), item("/a")]] {
            XCTAssertEqual(DropPlanner.proposal(sources: sources, destination: destination).rejection, .overlappingSources)
        }
    }
}
