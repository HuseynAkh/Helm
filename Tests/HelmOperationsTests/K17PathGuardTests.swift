// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations

final class K17PathGuardTests: XCTestCase {
    /// F-052/B-039: the executor independently rejects same-item aliases in hand-built plans.
    func testCaseInsensitiveSameItemCopyAndMove() async throws {
        for kind in [PlannedStep.Kind.copy, .move] {
            try await check(kind: kind, sensitive: false, source: "/a", target: "/A", expected: .invalidPlan)
        }
    }

    /// F-052/B-039: distinct case-sensitive names may be copied or moved.
    func testCaseSensitiveDistinctItemCopyAndMove() async throws {
        for kind in [PlannedStep.Kind.copy, .move] {
            try await check(kind: kind, sensitive: true, source: "/a", target: "/A", expected: nil)
        }
    }

    /// F-052: identical paths remain invalid under both volume semantics.
    func testExactSameItemRemainsRejected() async throws {
        for sensitive in [true, false] {
            for kind in [PlannedStep.Kind.copy, .move] {
                try await check(kind: kind, sensitive: sensitive, source: "/a", target: "/a", expected: .invalidPlan)
            }
        }
    }

    /// F-052: recursion is rejected even when the destination declares different semantics.
    func testRecursiveDestinationRemainsRejected() async throws {
        for kind in [PlannedStep.Kind.copy, .move] {
            try await check(kind: kind, sensitive: true, source: "/a", target: "/a/child", expected: .invalidPlan)
            try await check(kind: kind, sensitive: false, source: "/a", target: "/A/child", expected: .invalidPlan)
        }
    }

    /// F-052: a case-distinct sibling is not a descendant on a sensitive volume.
    func testCaseDistinctAncestorAllowsTransfer() async throws {
        for kind in [PlannedStep.Kind.copy, .move] {
            try await check(kind: kind, sensitive: true, source: "/a", target: "/A/child", expected: nil)
        }
    }

    /// F-052: containment uses component boundaries, not a bare string prefix.
    func testPrefixSiblingAllowsTransfer() async throws {
        for sensitive in [true, false] {
            try await check(kind: .copy, sensitive: sensitive, source: "/a", target: "/ab", expected: nil)
        }
    }

    /// F-052: absent capability data retains the conservative case-insensitive default.
    func testUnknownSensitivityRejectsCaseAlias() async throws {
        try await check(kind: .copy, sensitive: false, source: "/a", target: "/A",
                        expected: .invalidPlan, includeSensitivity: false)
    }

    private func check(kind: PlannedStep.Kind, sensitive: Bool, source: String, target: String,
                       expected: OperationError?, includeSensitivity: Bool = true) async throws {
        let fs = InMemoryFileSystem(caseSensitive: sensitive)
        let sourceURL = URL(fileURLWithPath: source)
        let targetURL = URL(fileURLWithPath: target)
        let root = URL(fileURLWithPath: "/")
        try await fs.createDirectory(at: sourceURL)
        let payload = sourceURL.appendingPathComponent("payload")
        try await fs.createFileExclusively(at: payload, contents: Data([1, 2, 3]))
        let parent = targetURL.deletingLastPathComponent()
        if !(await fs.exists(parent)) { try await fs.createDirectory(at: parent) }
        var semantics: [URL: Bool] = includeSensitivity ? [root: sensitive] : [:]
        // Deliberately disagree at the target parent: source ancestry must govern the guard.
        if parent != root { semantics[parent] = !sensitive }
        let step = PlannedStep(kind: kind, source: sourceURL, destination: targetURL)
        let plan = OperationPlan(command: .recovery, steps: [step], context: PlanningContext(caseSensitive: semantics))
        let result = await OperationExecutor(fileSystem: fs).execute(plan)
        XCTAssertEqual(result.error, expected)
        XCTAssertEqual(result.succeededCount, expected == nil ? 1 : 0)
        let sourceExists = await fs.exists(sourceURL)
        XCTAssertEqual(sourceExists, expected != nil || kind == .copy)
        if expected == nil {
            let entry = try await fs.entry(at: targetURL.appendingPathComponent("payload"))
            XCTAssertEqual(entry.size, 3)
        } else {
            let names = try await fs.childNames(of: sourceURL)
            XCTAssertEqual(names, ["payload"])
            XCTAssertFalse(try XCTUnwrap(result.outcomes.first).requiresReconciliation)
        }
    }
}
