#if os(macOS)
import XCTest
import HelmCore
import HelmOperations
@testable import HelmUI

/// The operations panel counts what a person chose, names what failed, and is tall enough to show a failed row's
/// Details. One replaced file is four steps for the engine and one item for everyone else.
@MainActor final class HuntOperationsPanelTests: XCTestCase {
    private let to = URL(fileURLWithPath: "/home/me/Desktop", isDirectory: true)
    private func replacing(_ name: String) -> [PlannedStep] {
        let item = StepID(), stage = to.appendingPathComponent(".helm-stage")
        let source = URL(fileURLWithPath: "/home/me/Locked").appendingPathComponent(name)
        return [PlannedStep(kind: .copy, source: source, destination: stage, item: item),
                PlannedStep(kind: .verifyCopy, source: source, destination: stage, item: item),
                PlannedStep(kind: .trash, source: to.appendingPathComponent(name), item: item),
                PlannedStep(kind: .move, source: stage, destination: to.appendingPathComponent(name), item: item)]
    }
    private func copying(_ name: String) -> PlannedStep {
        PlannedStep(kind: .copy, source: URL(fileURLWithPath: "/home/me/Locked").appendingPathComponent(name),
                    destination: to.appendingPathComponent(name))
    }

    func testAFinishedRowCountsItemsAndNamesTheOneThatFailed() {
        let id = OperationID()
        let steps = replacing("1-locked.txt") + [copying("2-open.txt"), copying("3-open.txt")]
        let denied = OperationError.other("permissionDenied")
        let outcomes = [ItemOutcome(step: steps[0], destination: steps[0].destination, result: .failure(denied))]
            + steps[1...3].map { ItemOutcome(step: $0, destination: $0.destination, result: .failure(.notAttempted)) }
            + steps[4...].map { ItemOutcome(step: $0, destination: $0.destination, result: .success(nil)) }
        let result = OperationResult(id: id, command: .copy(sources: [], destinationDirectory: to), outcomes: outcomes, error: denied)
        let row = OperationRowModel(id: id, title: "Copying 3 items", result: result)
        XCTAssertEqual(row.status, "2 of 3 done. “1-locked.txt”: You don’t have permission.")
        XCTAssertFalse(row.status.contains(".helm-stage"))
        XCTAssertGreaterThan(row.panelHeight, OperationRowModel(id: OperationID(), title: "Copying").panelHeight,
                             "a finished row with Details is taller than a running one")
    }

    func testTwoFailedItemsAreNamedAsOneAndMore() {
        let id = OperationID()
        let steps = [copying("a.txt"), copying("b.txt"), copying("c.txt")]
        let outcomes = [ItemOutcome(step: steps[0], destination: nil, result: .failure(.conflict)),
                        ItemOutcome(step: steps[1], destination: nil, result: .failure(.conflict)),
                        ItemOutcome(step: steps[2], destination: steps[2].destination, result: .success(nil))]
        let result = OperationResult(id: id, command: .copy(sources: [], destinationDirectory: to), outcomes: outcomes, error: .conflict)
        XCTAssertEqual(OperationRowModel(id: id, title: "Copying 3 items", result: result).status,
                       "1 of 3 done. “a.txt” and 1 more: An item with that name is already there.")
    }

    /// While it runs, a replaced file reads as one item, named as itself, at every one of its steps.
    func testProgressCountsItemsAndNeverNamesTheStage() {
        let items = PlanItems(replacing("1-locked.txt") + [copying("2-open.txt")])
        let id = OperationID()
        let moving = OperationCoordinator.itemProgress(OperationProgress(id: id, itemsDone: 3, itemsTotal: 5, currentName: ".helm-stage"), items: items)
        XCTAssertEqual(moving.itemsDone, 0); XCTAssertEqual(moving.itemsTotal, 2)
        XCTAssertEqual(moving.currentName, "1-locked.txt")
        let next = OperationCoordinator.itemProgress(OperationProgress(id: id, itemsDone: 4, itemsTotal: 5, currentName: "2-open.txt"), items: items)
        XCTAssertEqual(OperationRowModel(id: id, title: "Copying 2 items", progress: next).status, "1 of 2 · 2-open.txt")
    }
}
#endif
