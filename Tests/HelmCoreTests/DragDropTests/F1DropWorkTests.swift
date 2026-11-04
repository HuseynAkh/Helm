// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class F1DropWorkTests: XCTestCase {
    func testOverlapValidationHasLinearPrefixCheckBound() {
        let paths = (0..<1_000).map { ["/", "source", "file\($0)"] }
        var checks: Int = 0
        XCTAssertFalse(DropPlanner.hasOverlappingPaths(paths) { path, prefix in
            checks += 1
            return path.starts(with: prefix)
        })
        XCTAssertLessThanOrEqual(checks, paths.count)
    }

    func testPermutationsMatchAllPairsReference() {
        let candidates = ["/a", "/a/b", "/ab", "/z", "/", "/a/../a"]
        for first in candidates {
            for second in candidates {
                for third in candidates {
                    let paths = [first, second, third].map { URL(fileURLWithPath: $0).standardizedFileURL.pathComponents }
                    let expected = paths.indices.contains { i in
                        paths.indices.contains { j in i != j && paths[i].starts(with: paths[j]) }
                    }
                    XCTAssertEqual(DropPlanner.hasOverlappingPaths(paths), expected)
                }
            }
        }
        XCTAssertFalse(DropPlanner.hasOverlappingPaths([]))
        XCTAssertFalse(DropPlanner.hasOverlappingPaths([["/"]]))
    }

    func testLargeUnrelatedSelectionPreservesExecutionOrder() {
        let sources = (0..<10_000).reversed().map {
            DraggedItem(url: URL(fileURLWithPath: "/source/file\($0)"), volumeID: "v")
        }
        let start = Date()
        let proposal = DropPlanner.proposal(sources: sources,
            destination: DropDestination(location: .directory(URL(fileURLWithPath: "/target")), volumeID: "v"))
        print("F1 diagnostic 10k drag seconds: \(Date().timeIntervalSince(start))")
        XCTAssertEqual(proposal.operation, .move)
        XCTAssertEqual(proposal.sources, sources)
    }
}
