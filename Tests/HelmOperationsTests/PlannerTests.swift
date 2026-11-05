// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
import HelmFileSystem
@testable import HelmOperations

final class PlannerTests: XCTestCase {
    let a = URL(fileURLWithPath: "/a")
    let b = URL(fileURLWithPath: "/b")
    func context(names: Set<String> = [], policy: ConflictPolicy = ConflictPolicy(), sensitive: Bool = false) -> PlanningContext {
        PlanningContext(caseSensitive: [a: sensitive, b: sensitive], existingNames: [a: ["x.txt", "y.txt"], b: names],
                        volumeIDs: [a.appendingPathComponent("x.txt"): "v", b: "v", a: "v"], defaultPolicy: policy)
    }
    func testVirtualTargetsAndSameParentMove() {
        let source = a.appendingPathComponent("x.txt")
        for location in [Location.recent, .trash] {
            let plan = OperationPlanner.transfer(sources: [source], to: location, moving: false, context: context())
            XCTAssertEqual(plan.issues, [.virtualLocationTarget]); XCTAssertFalse(plan.isExecutable)
        }
        let plan = OperationPlanner.transfer(sources: [source], to: .directory(a), moving: true, context: context())
        XCTAssertTrue(plan.isExecutable); XCTAssertTrue(plan.steps.isEmpty); XCTAssertEqual(plan.issues, [.sameParentMove(source)])
    }
    func testDescendantsOverlapsAndNonFileURLsAreRejected() throws {
        let child = a.appendingPathComponent("child")
        XCTAssertFalse(OperationPlanner.plan(.copy(sources: [a], destinationDirectory: child), context: context()).isExecutable)
        XCTAssertFalse(OperationPlanner.plan(.trash(items: [a, child]), context: context()).isExecutable)
        XCTAssertFalse(OperationPlanner.plan(.trash(items: [a, a]), context: context()).isExecutable)
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/a"))
        XCTAssertFalse(OperationPlanner.plan(.trash(items: [remote]), context: context()).isExecutable)
    }
    func testNamingUsesK2ExtensionAndCaseRules() {
        let source = a.appendingPathComponent("a.tar.gz")
        let plan = OperationPlanner.plan(.copy(sources: [source], destinationDirectory: b), context: context(names: ["A.TAR.GZ", "a.tar 2.gz"]))
        XCTAssertEqual(plan.steps.first?.destination?.lastPathComponent, "a.tar 3.gz")
        let exact = OperationPlanner.plan(.copy(sources: [source], destinationDirectory: b), context: context(names: ["A.TAR.GZ"], sensitive: true))
        XCTAssertEqual(exact.steps.first?.destination?.lastPathComponent, "a.tar.gz")
    }
    func testConflictPoliciesAndResolution() {
        let source = a.appendingPathComponent("x.txt")
        let command = Command.copy(sources: [source], destinationDirectory: b)
        let initial = OperationPlanner.plan(command, context: context(names: ["x.txt"]))
        XCTAssertEqual(initial.steps.first?.destination?.lastPathComponent, "x 2.txt")
        XCTAssertTrue(OperationPlanner.resolve(initial, with: ConflictPolicy(defaultResolution: .skip)).steps.isEmpty)
        XCTAssertFalse(OperationPlanner.resolve(initial, with: ConflictPolicy(defaultResolution: .stop)).isExecutable)
        let replace = OperationPlanner.resolve(initial, with: ConflictPolicy(defaultResolution: .replace))
        XCTAssertEqual(replace.steps.map(\.kind), [.copy, .verifyCopy, .trash, .move])
        let all = ConflictPolicy(defaultResolution: .skip, perItem: [source: .replace], applyToAll: true)
        XCTAssertEqual(all.resolution(for: source), .skip)
        XCTAssertEqual(ConflictPolicy(perItem: [source: .replace]).resolution(for: source), .replace)
    }
    func testDuplicateAndCreation() throws {
        let source = a.appendingPathComponent("x.txt")
        let duplicate = OperationPlanner.plan(.duplicate(sources: [source]), context: context())
        XCTAssertEqual(duplicate.steps.first?.destination?.lastPathComponent, "x 2.txt")
        let name = try XCTUnwrap(ValidFileName("x.txt"))
        let folder = OperationPlanner.plan(.createFolder(parent: a, name: name), context: context())
        XCTAssertEqual(folder.steps.first?.kind, .createDirectory)
        XCTAssertEqual(folder.steps.first?.destination?.lastPathComponent, "x 2.txt")
        let file = OperationPlanner.plan(.createFile(parent: b, name: name, template: nil), context: context())
        XCTAssertEqual(file.steps.first?.kind, .createFile)
        let template = OperationPlanner.plan(.createFile(parent: b, name: name, template: source), context: context())
        XCTAssertEqual(template.steps.first?.kind, .copy)
        XCTAssertFalse(OperationPlanner.plan(.createFolder(parent: a, name: name), context: PlanningContext()).isExecutable)
    }
    func testBatchSwapsCaseRenameAndCollision() throws {
        let x = a.appendingPathComponent("x.txt"), y = a.appendingPathComponent("y.txt")
        let pairs = [RenamePair(source: x, newName: try XCTUnwrap(ValidFileName("y.txt"))),
                     RenamePair(source: y, newName: try XCTUnwrap(ValidFileName("x.txt")))]
        let plan = OperationPlanner.plan(.batchRename(pairs), context: context())
        XCTAssertEqual(plan.steps.count, 4)
        XCTAssertTrue(plan.steps[0].destination?.lastPathComponent.hasPrefix(".helm-rename-") == true)
        XCTAssertFalse(OperationPlanner.plan(.rename(pairs[0]), context: context()).isExecutable)
        let casing = RenamePair(source: x, newName: try XCTUnwrap(ValidFileName("X.txt")))
        XCTAssertEqual(OperationPlanner.plan(.rename(casing), context: context()).steps.count, 2)
    }
    func testCrossVolumePlanAndCapacityPreflight() {
        let source = a.appendingPathComponent("x.txt")
        let context = PlanningContext(existingNames: [b: []])
        let plan = OperationPlanner.plan(.move(sources: [source], destinationDirectory: b), context: context)
        XCTAssertEqual(plan.steps.map(\.kind), [.copy, .verifyCopy, .trash])
        let token = ChangeToken(modificationDate: .distantPast, size: 100, childCount: nil)
        let low = PlanningContext(sourceManifest: [SourceEntry(source: source, relativePath: "", kind: .regular, size: 100, changeToken: token)],
                                  availableBytes: [b: 50], existingNames: [b: []])
        XCTAssertFalse(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: b), context: low).isExecutable)
    }
}
