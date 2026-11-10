// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class K34CancellationTests: XCTestCase {
    func testCancellationStopsGenerationWithoutPartialPlan() {
        var checks = 0
        XCTAssertThrowsError(try BatchRenamePlanner.plan(
            items: (0..<100).map { URL(fileURLWithPath: "/item\($0)") },
            rule: .addText(prepend: "new", append: ""), cancellationCheck: {
                checks += 1
                if checks == 4 { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 4)
    }

    func testCancellationInterruptsTemporaryCollisionProbing() throws {
        let source = URL(fileURLWithPath: "/a")
        let rename = RenamePair(source: source, newName: try FileNameValidator.validate("b").get())
        var checks = 0
        XCTAssertThrowsError(try BatchRenamePlanner.plan(renames: [rename],
            existingNames: [URL(fileURLWithPath: "/"): Set((1...100).map {
                $0 == 1 ? ".helm-rename-1" : ".helm-rename-1 \($0)"
            })], cancellationCheck: {
                checks += 1
                if checks == 150 { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 150)
    }
}

extension K34CancellationTests {
    func testCancellationHookErrorPropagatesExactlyOnceFromTemporaryProbe() throws {
        enum Stop: Error { case requested }
        let rename = RenamePair(source: URL(fileURLWithPath: "/a"), newName: try FileNameValidator.validate("b").get())
        var probes = 0
        // First measure the deterministic successful path, then stop at its last probe.
        _ = try BatchRenamePlanner.plan(renames: [rename], cancellationCheck: { probes += 1 })
        var checks = 0
        XCTAssertThrowsError(try BatchRenamePlanner.plan(renames: [rename], cancellationCheck: {
            checks += 1
            if checks == probes { throw Stop.requested }
        })) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(checks, probes)
    }
}
