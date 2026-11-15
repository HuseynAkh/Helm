import XCTest
import HelmCore
@testable import HelmAgent

/// Handles: how they are named, that one item keeps its handle, that a retired handle answers as stale, that
/// counters never go back, and the cap on handles in one thread.
final class AgentHandleTableTests: XCTestCase {
    private func item(_ path: String, _ kind: FileEntryKind = .regular, object: String? = nil) -> AgentDiskItem {
        AgentDiskItem(path: path, name: String(path.split(separator: "/").last ?? ""), kind: kind,
                      identity: FileObjectIdentity(scope: "test", object: object ?? path))
    }

    func testHandlesAreNamedByKindAndARootsHandleIsItsAlias() async {
        let table = AgentHandleTable()
        let alias = await table.nextRootAlias()
        XCTAssertEqual(alias, "r1")
        let root = await table.mint(rootAlias: alias, item: item("/home/helm", .directory), isRoot: true, isProtectedLeaf: false)
        let folder = await table.mint(rootAlias: alias, item: item("/home/helm/Old", .directory), isRoot: false, isProtectedLeaf: false)
        let file = await table.mint(rootAlias: alias, item: item("/home/helm/a.png"), isRoot: false, isProtectedLeaf: false)
        let package = await table.mint(rootAlias: alias, item: item("/home/helm/Thing.app", .package), isRoot: false, isProtectedLeaf: false)
        let leaf = await table.mint(rootAlias: alias, item: item("/home/helm/Documents", .directory), isRoot: false, isProtectedLeaf: true)
        XCTAssertEqual(root.handle, "r1")
        XCTAssertTrue(root.isRoot)
        XCTAssertEqual(folder.handle, "d1")
        XCTAssertEqual(file.handle, "f2")
        XCTAssertEqual(package.handle, "f3")
        XCTAssertEqual(leaf.handle, "d4")
        XCTAssertTrue(leaf.isProtectedLeaf)
        XCTAssertEqual(file.path, "/home/helm/a.png")
        XCTAssertEqual(file.name, "a.png")
        let count = await table.count
        XCTAssertEqual(count, 5)
        let found = await table.record(for: "f2")
        XCTAssertEqual(found, file)
        let unknown = await table.record(for: "f99")
        XCTAssertNil(unknown)
        let unknownRetired = await table.isRetired("f99")
        XCTAssertFalse(unknownRetired)
    }

    func testTheSameItemKeepsItsHandleAndAReplacedOneGetsANewOne() async {
        let table = AgentHandleTable()
        let first = await table.mint(rootAlias: "r1", item: item("/home/helm/a.png"), isRoot: false, isProtectedLeaf: false)
        let again = await table.mint(rootAlias: "r1", item: item("/home/helm/a.png"), isRoot: false, isProtectedLeaf: false)
        XCTAssertEqual(first.handle, again.handle)
        // Under another root the same item has a handle of its own.
        let elsewhere = await table.mint(rootAlias: "r2", item: item("/home/helm/a.png"), isRoot: false, isProtectedLeaf: false)
        XCTAssertNotEqual(elsewhere.handle, first.handle)
        let replaced = await table.mint(rootAlias: "r1", item: item("/home/helm/a.png", object: "another"), isRoot: false, isProtectedLeaf: false)
        XCTAssertNotEqual(replaced.handle, first.handle)
        let old = await table.record(for: first.handle)
        XCTAssertNil(old)
        let stale = await table.isRetired(first.handle)
        XCTAssertTrue(stale)
    }

    func testRetiredHandlesAnswerStale() async {
        let table = AgentHandleTable()
        _ = await table.mint(rootAlias: "r1", item: item("/a", .directory), isRoot: true, isProtectedLeaf: false)
        let one = await table.mint(rootAlias: "r1", item: item("/a/x"), isRoot: false, isProtectedLeaf: false)
        let two = await table.mint(rootAlias: "r2", item: item("/b/y"), isRoot: false, isProtectedLeaf: false)
        await table.retire(rootAlias: "r1")
        for handle in ["r1", one.handle] {
            let record = await table.record(for: handle)
            XCTAssertNil(record, handle)
            let retired = await table.isRetired(handle)
            XCTAssertTrue(retired, handle)
        }
        let kept = await table.record(for: two.handle)
        XCTAssertEqual(kept, two)

        await table.retireAll()
        let retiredTwo = await table.isRetired(two.handle)
        XCTAssertTrue(retiredTwo)
        let count = await table.count
        XCTAssertEqual(count, 0)
        // A root minted again after everything was retired is live again; nothing else is.
        let root = await table.mint(rootAlias: "r1", item: item("/a", .directory), isRoot: true, isProtectedLeaf: false)
        XCTAssertEqual(root.generation, 1)
        let rootRetired = await table.isRetired("r1")
        XCTAssertFalse(rootRetired)
        // A handle is never issued again: the next item gets a new number.
        let next = await table.mint(rootAlias: "r1", item: item("/a/x"), isRoot: false, isProtectedLeaf: false)
        XCTAssertNotEqual(next.handle, one.handle)
    }

    func testRootAliasesNeverGoBack() async {
        let table = AgentHandleTable()
        var aliases: [String] = []
        for _ in 0..<3 { aliases.append(await table.nextRootAlias()) }
        await table.retireAll()
        for _ in 0..<2 { aliases.append(await table.nextRootAlias()) }
        XCTAssertEqual(aliases, ["r1", "r2", "r3", "r4", "r5"])
    }

    func testTheTwentyThousandCap() async {
        let table = AgentHandleTable()
        for index in 0..<(AgentLimits.handlesPerThread - 1) {
            _ = await table.mint(rootAlias: "r1", item: item("/a/\(index)"), isRoot: false, isProtectedLeaf: false)
        }
        let nearlyFull = await table.isFull
        XCTAssertFalse(nearlyFull)
        _ = await table.mint(rootAlias: "r1", item: item("/a/last"), isRoot: false, isProtectedLeaf: false)
        let full = await table.isFull
        XCTAssertTrue(full)
        let count = await table.count
        XCTAssertEqual(count, 20_000)
    }

    func testAScopeStopsMakingHandlesAtTheCap() async {
        let home = "/home/helm"
        let disk = MemoryAgentDisk(home: home)
        for index in 0..<(AgentLimits.handlesPerThread + 5) { disk.addFile(home + "/Big/file\(index).txt") }
        disk.addFile(home + "/Big/zzz.txt")
        let scope = AgentScope(disk: disk, home: home, supportFolder: "/home/support")
        guard case .root(let big) = await scope.setTabFolder(AgentRootInput(fromPerson: home + "/Big", origin: .tab)) else {
            return XCTFail("no tab root")
        }
        let folder = await scope.record(for: big.alias)!
        let listed = await scope.listing(of: folder, limit: 30_000, idleSeconds: 10, recheckingFirst: true)
        XCTAssertTrue(listed.outOfHandles)
        XCTAssertEqual(listed.entries.count, AgentLimits.handlesPerThread - 1, "the root holds one handle")
        agentEqual(await scope.admit(childNamed: "zzz.txt", in: folder), .failure(.limit_reached))
        // Starting over frees the handles.
        await scope.startOver()
        guard case .success = await scope.admit(childNamed: "zzz.txt", in: (await scope.record(for: big.alias))!) else {
            return XCTFail("no handle after starting over")
        }
    }
}
