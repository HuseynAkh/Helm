import XCTest
import HelmCore
@testable import HelmAgent

/// The numbers that bound a request, and the fixed lists other code switches over.
final class AgentLimitsTests: XCTestCase {
    func testTheLimitsForAProviderOnTheInternet() {
        let limits = AgentLimits.cloudModel
        XCTAssertEqual([limits.turns, limits.callsPerRequest, limits.callsPerTurn], [12, 24, 8])
        XCTAssertEqual([limits.entriesPerPage, limits.entriesPerRequest, limits.maxDepth, limits.findResults], [500, 5_000, 8, 200])
        XCTAssertEqual([limits.planSteps, limits.planNewFolders, limits.plansPerRequest, limits.badArguments], [1_000, 100, 2, 2])
        XCTAssertEqual([limits.messageCharacters, limits.replyCharacters], [4_000, 8_000])
        XCTAssertEqual([limits.requestSeconds, limits.listSeconds], [600, 3])
    }

    func testTheLimitsForAModelOnThisMac() {
        let limits = AgentLimits.localModel
        XCTAssertEqual([limits.turns, limits.callsPerRequest, limits.callsPerTurn], [8, 12, 4])
        XCTAssertEqual([limits.entriesPerPage, limits.entriesPerRequest, limits.maxDepth, limits.findResults], [150, 1_000, 8, 60])
        XCTAssertEqual([limits.planSteps, limits.planNewFolders, limits.plansPerRequest, limits.badArguments], [200, 40, 2, 2])
        XCTAssertEqual([limits.messageCharacters, limits.replyCharacters], [4_000, 8_000])
        XCTAssertEqual([limits.requestSeconds, limits.listSeconds], [1_200, 3])
    }

    func testAPlaceOnThisMacOrADiskKeepsTheLimits() {
        XCTAssertEqual(AgentLimits.cloudModel.adjusted(for: .thisMac), .cloudModel)
        XCTAssertEqual(AgentLimits.cloudModel.adjusted(for: .external), .cloudModel)
        XCTAssertEqual(AgentLimits.localModel.adjusted(for: .thisMac), .localModel)
    }

    func testACloudFolderLowersTheLimits() {
        for kind in [StorageKind.iCloud, .cloud] {
            let limits = AgentLimits.cloudModel.adjusted(for: kind)
            XCTAssertEqual(limits.maxDepth, 6)
            XCTAssertEqual(limits.planSteps, 500)
            XCTAssertEqual(limits.listSeconds, 8)
            XCTAssertEqual(limits.entriesPerRequest, 5_000)
            var expected = AgentLimits.cloudModel
            expected.maxDepth = 6; expected.planSteps = 500; expected.listSeconds = 8
            XCTAssertEqual(limits, expected, "nothing else changes")
            // A limit that is already lower stays as it is.
            let local = AgentLimits.localModel.adjusted(for: kind)
            XCTAssertEqual([local.maxDepth, local.planSteps, local.entriesPerRequest], [6, 200, 1_000])
            XCTAssertEqual(local.listSeconds, 8)
        }
    }

    func testAServerLowersThemFurther() {
        let limits = AgentLimits.cloudModel.adjusted(for: .network)
        var expected = AgentLimits.cloudModel
        expected.maxDepth = 4; expected.entriesPerRequest = 2_000; expected.planSteps = 200; expected.listSeconds = 10
        XCTAssertEqual(limits, expected)
        let local = AgentLimits.localModel.adjusted(for: .network)
        XCTAssertEqual([local.maxDepth, local.entriesPerRequest, local.planSteps], [4, 1_000, 200])
        XCTAssertEqual(local.listSeconds, 10)
        // Adjusting twice changes nothing more.
        XCTAssertEqual(limits.adjusted(for: .network), limits)
    }

    func testAFixtureRunsShortWaitIsAppliedLast() {
        let limits = AgentLimits.cloudModel.adjusted(for: .network).scaled(listSeconds: 0.5)
        XCTAssertEqual(limits.listSeconds, 0.5)
        var expected = AgentLimits.cloudModel.adjusted(for: .network)
        expected.listSeconds = 0.5
        XCTAssertEqual(limits, expected, "only the listing's time changes")
        XCTAssertEqual(AgentLimits.localModel.scaled(listSeconds: 20).listSeconds, 20)
        XCTAssertEqual(AgentLimits.localModel.scaled(listSeconds: -1).listSeconds, 0)
    }

    func testTheFixedNumbers() {
        XCTAssertEqual(AgentLimits.roots, 8)
        XCTAssertEqual(AgentLimits.threadRequests, 30)
        XCTAssertEqual(AgentLimits.threadBytes, 8_000_000)
        XCTAssertEqual(AgentLimits.handlesPerThread, 20_000)
        XCTAssertEqual(AgentLimits.bulkShared, 25)
        XCTAssertEqual(AgentLimits.newFolderLevels, 4)
        XCTAssertEqual(AgentLimits.callIDCharacters, 128)
        XCTAssertEqual(AgentLimits.holdsCap, 1_000)
        XCTAssertEqual(AgentLimits.datalessWalk, 2_000)
        XCTAssertEqual(AgentLimits.diskSeconds, 2)
        XCTAssertEqual(AgentJSON.maxDepth, 32)
    }

    func testWhatMayComeBackFromAProvider() {
        let cloud = AgentTransportLimits.cloud, local = AgentTransportLimits.local
        XCTAssertEqual([cloud.idleSeconds, cloud.totalSeconds], [120, 900])
        XCTAssertEqual([local.idleSeconds, local.totalSeconds], [300, 900])
        for limits in [cloud, local] {
            XCTAssertEqual([limits.lineBytes, limits.responseBytes, limits.listBytes, limits.retries], [4_000_000, 32_000_000, 4_000_000, 2])
        }
        XCTAssertNotEqual(cloud, local)
    }

    func testTheFixedLists() {
        XCTAssertEqual(AgentFailure.allCases.map(\.rawValue), [
            "off", "notReady", "noKey", "keyDenied", "wrongKey", "outOfCredit", "rateLimited", "overloaded", "noSuchModel", "noTools",
            "badRequest", "tooLarge", "unreachable", "notRunning", "timedOut", "unreadable", "cancelled", "declined"
        ])
        XCTAssertEqual(AgentStop.failed(.timedOut), .failed(.timedOut))
        XCTAssertNotEqual(AgentStop.failed(.timedOut), .failed(.unreachable))
        XCTAssertNotEqual(AgentStop.endTurn, .toolUse)
        XCTAssertEqual(AgentTransportError.http(status: 429, body: Data("x".utf8)), .http(status: 429, body: Data("x".utf8)))
        XCTAssertNotEqual(AgentTransportError.http(status: 429, body: Data()), .http(status: 500, body: Data()))
        XCTAssertNotEqual(AgentTransportError.keyInBody, .insecure)
        XCTAssertEqual(AgentEndpointRefusal(rawValue: "otherDevice"), .otherDevice)
        XCTAssertEqual(AgentScopeRefusal(rawValue: "insidePackage"), .insidePackage)
    }

    func testTheSmallValuesKeepWhatTheyAreGiven() {
        let call = AgentToolCall(id: "call_1", name: "list_folder", arguments: Data("{}".utf8))
        XCTAssertEqual(call, AgentToolCall(id: "call_1", name: "list_folder", arguments: Data("{}".utf8)))
        let result = AgentToolResult(callID: "call_1", name: "list_folder", json: "{}")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(AgentToolResult(callID: "call_1", name: "list_folder", json: "{}", isError: true).isError)
        XCTAssertEqual(AgentHTTPReply(status: 200, body: Data("ok".utf8)).status, 200)

        let record = AgentHandleRecord(handle: "f12", rootAlias: "r1", path: "/home/helm/a.png", name: "a.png", kind: .regular,
                                       identity: nil, size: 410_000, modified: .distantPast, isDataless: false, isRoot: false, generation: 3)
        XCTAssertFalse(record.isProtectedLeaf, "a leaf is protected only when it is said to be")
        XCTAssertEqual(record.generation, 3)

        let input = AgentPersonInput(typedByPerson: "organize", selectedPaths: ["/home/helm/a.png"])
        XCTAssertEqual([input.text] + input.selectedPaths, ["organize", "/home/helm/a.png"])
        let folder = AgentRootInput(fromPerson: "~/Pictures", origin: .dropped)
        XCTAssertEqual(folder.text, "~/Pictures")
        XCTAssertEqual(folder.origin, .dropped)
        XCTAssertEqual(AgentTabFolder.none, AgentTabFolder.none)
        XCTAssertNotEqual(AgentTabFolder.none, .refused(.hidden))
        XCTAssertEqual(AgentPlanOutcome.applied(done: 210, skipped: 4), .applied(done: 210, skipped: 4))
        XCTAssertNotEqual(AgentPlanOutcome.applied(done: 210, skipped: 4), .dismissed)
        XCTAssertEqual(AgentTrace.sent(names: 80, destination: "Claude"), .sent(names: 80, destination: "Claude"))
        XCTAssertEqual(AgentStatus.reading(count: 3), .reading(count: 3))
        XCTAssertEqual(AgentNotice.foldersNotLoaded(2), .foldersNotLoaded(2))
        XCTAssertEqual(AgentRecheck.notResponding(label: "Server"), .notResponding(label: "Server"))
        XCTAssertEqual(AgentApplyTicket.refused, .refused)
    }
}
