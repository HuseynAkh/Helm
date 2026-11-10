// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

/// F-055/B-047: cancellation must propagate from every checkpoint without returning partial work.
final class T3CancellationTests: XCTestCase {
    private enum Stop: Error, Equatable { case probe(Int) }
    private func verify(size: Int, occupied: Int) throws {
        let root = URL(fileURLWithPath: "/rename")
        let items = (0..<size).map { root.appendingPathComponent("item\($0)") }
        let names = Set((1...max(1, occupied)).prefix(occupied).map { $0 == 1 ? ".helm-rename-1" : ".helm-rename-1 \($0)" })
        var count = 0
        let plan = try BatchRenamePlanner.plan(items: items, rule: .addText(prepend: "new-", append: ""), existingNames: [root: names], cancellationCheck: { count += 1 })
        XCTAssertTrue(plan.canExecute)
        XCTAssertEqual(plan.steps.count, size * 2)
        XCTAssertEqual(plan.previews.map(\.proposedName), (0..<size).map { "new-item\($0)" })
        let again = BatchRenamePlanner.plan(items: items, rule: .addText(prepend: "new-", append: ""), existingNames: [root: names])
        XCTAssertEqual(plan.steps, again.steps)
        XCTAssertGreaterThan(count, size)
        for stop in 1...count {
            var checks = 0
            XCTAssertThrowsError(try BatchRenamePlanner.plan(items: items, rule: .addText(prepend: "new-", append: ""), existingNames: [root: names], cancellationCheck: {
                checks += 1
                if checks == stop { throw Stop.probe(stop) }
            })) { XCTAssertEqual($0 as? Stop, .probe(stop)) }
            XCTAssertEqual(checks, stop)
        }
    }
    func testEveryCheckpointSize1Occupied0() throws { try verify(size: 1, occupied: 0) }
    func testEveryCheckpointSize2Occupied0() throws { try verify(size: 2, occupied: 0) }
    func testEveryCheckpointSize3Occupied0() throws { try verify(size: 3, occupied: 0) }
    func testEveryCheckpointSize10Occupied0() throws { try verify(size: 10, occupied: 0) }
    func testEveryCheckpointSize1Occupied1() throws { try verify(size: 1, occupied: 1) }
    func testEveryCheckpointSize1Occupied20() throws { try verify(size: 1, occupied: 20) }
    func testEveryCheckpointSize3Occupied7() throws { try verify(size: 3, occupied: 7) }
    func testEveryCheckpointSize12Occupied10() throws { try verify(size: 12, occupied: 10) }
}
