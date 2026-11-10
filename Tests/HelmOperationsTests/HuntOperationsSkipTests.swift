import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmTestKit
@testable import HelmOperations

/// Skip, Try Again and Stop are about items (P-139). A Replace is several steps for one item, and skipping the
/// item that couldn't be copied must not carry on with the rest of its steps.
final class HuntOperationsSkipTests: XCTestCase {
    private var root: URL!
    private var fs: LiveFileSystem!
    private var executor: OperationExecutor!
    private var locked: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("helm-hunt-skip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fs = LiveFileSystem(trash: fixtureTrash(in: root.appendingPathComponent("trash")))
        executor = OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins())
    }
    override func tearDownWithError() throws {
        for url in locked { chmod(url.path, 0o644) }
        try FileManager.default.removeItem(at: root)
    }

    private func file(_ path: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func trashed() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("trash").path)) ?? []
    }

    func testSkippingAnItemThatCouldntReplaceLeavesTheExistingOneAlone() async throws {
        let source = try file("from/report.txt", "new")
        XCTAssertEqual(chmod(source.path, 0), 0)
        locked.append(source)
        let existing = try file("to/report.txt", "keep")
        let destination = existing.deletingLastPathComponent()
        let command = Command.copy(sources: [source], destinationDirectory: destination)
        let context = try await PlanningContextBuilder(fileSystem: fs)
            .build(sources: [source], destinations: [destination], policy: ConflictPolicy(defaultResolution: .replace, applyToAll: true))
        let plan = OperationPlanner.plan(command, context: context)
        XCTAssertTrue(plan.isExecutable, "\(plan.issues)")
        let questions = QuestionLog()
        _ = await executor.execute(plan, decide: { failure in
            await questions.add(failure)
            return .skip
        })
        let asked = await questions.all
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path),
                      "Skip left “report.txt” out, so the one already there must stay; trashed: \(trashed())")
        XCTAssertEqual(try? String(contentsOf: existing, encoding: .utf8), "keep")
        XCTAssertEqual(trashed(), [], "nothing was replaced, so nothing goes to the Trash")
        XCTAssertEqual(asked.count, 1, "one item couldn't be copied, so one question: \(asked.map { "\($0.name) remaining \($0.remaining)" })")
        XCTAssertEqual(asked.first?.remaining, 0, "no other item is still to do")
        XCTAssertFalse(asked.contains { $0.name.hasPrefix(".helm-stage") }, "a question never names Helm's private working copy")
    }

    /// The question counts items, not steps: one replaced item followed by one plain copy is "1 more item".
    func testTheQuestionCountsItemsStillToDo() async throws {
        let first = try file("from/a.txt", "new")
        XCTAssertEqual(chmod(first.path, 0), 0)
        locked.append(first)
        let second = try file("from/b.txt", "b")
        _ = try file("to/a.txt", "keep")
        let destination = root.appendingPathComponent("to", isDirectory: true)
        let context = try await PlanningContextBuilder(fileSystem: fs)
            .build(sources: [first, second], destinations: [destination], policy: ConflictPolicy(defaultResolution: .replace, applyToAll: true))
        let plan = OperationPlanner.plan(.copy(sources: [first, second], destinationDirectory: destination), context: context)
        XCTAssertTrue(plan.isExecutable, "\(plan.issues)")
        let questions = QuestionLog()
        _ = await executor.execute(plan, decide: { failure in
            await questions.add(failure)
            return .stop
        })
        let asked = await questions.all
        XCTAssertEqual(asked.first?.name, "a.txt")
        XCTAssertEqual(asked.first?.remaining, 1, "only b.txt is still to do")
    }
}

private actor QuestionLog {
    private(set) var all: [StepFailure] = []
    func add(_ failure: StepFailure) { all.append(failure) }
}
