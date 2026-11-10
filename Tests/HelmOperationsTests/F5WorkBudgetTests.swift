// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmOperations

final class F5WorkBudgetTests: XCTestCase {
    func testProductionPlannerWorkWithNonemptyManifest() {
        let count = 2048
        let parent = URL(fileURLWithPath: "/target")
        let sources = (0..<count).map { URL(fileURLWithPath: "/source/file\($0)") }
        let token = ChangeToken(modificationDate: .distantPast, size: 7)
        // Include unrelated entries: a per-source manifest scan must exceed the budget.
        let manifest = (sources + (0..<count).map { URL(fileURLWithPath: "/unrelated/file\($0)") }).map {
            SourceEntry(source: $0, relativePath: "", kind: .regular, size: 7, changeToken: token)
        }
        let context = PlanningContext(sourceManifest: manifest, availableBytes: [parent: Int64(count * 7)],
            existingNames: [parent: []])
        let work = PlannerWork()
        let plan = OperationPlanner.plan(.copy(sources: sources, destinationDirectory: parent), context: context, work: work)
        XCTAssertTrue(plan.isExecutable)
        XCTAssertEqual(plan.steps.count, count)
        XCTAssertEqual(work.targetQueries, count)
        XCTAssertGreaterThan(work.selectionComparisons, 0)
        XCTAssertLessThanOrEqual(work.selectionComparisons, count * 8)
        XCTAssertEqual(work.manifestVisits, manifest.count)
        XCTAssertEqual(work.manifestAggregations, manifest.count * 2)
        XCTAssertEqual(work.byteLookups, count)
    }

    func testJournalDuplicateInsertionWorkIsLinear() async {
        let count = 4096
        let steps = (0..<count).map { PlannedStep(kind: .createFile, destination: URL(fileURLWithPath: "/target/\($0)")) }
        let journal = OperationJournal()
        let id = await journal.begin(OperationPlan(command: .recovery, steps: steps))
        for step in steps {
            let outcome = ItemOutcome(step: step, destination: step.destination, result: .success(nil))
            await journal.record(outcome, for: id)
            await journal.record(outcome, for: id)
        }
        let probes = await journal.membershipChecks
        let outcomes = await journal.outcomes(for: id)
        XCTAssertEqual(probes, count * 2)
        XCTAssertEqual(outcomes.map { $0.step.id }, steps.map(\.id))
    }
}
