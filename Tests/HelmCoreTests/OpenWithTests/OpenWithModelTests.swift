// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class OpenWithModelTests: XCTestCase {
    private let a = ItemID(rawValue: "/a.txt")
    private let b = ItemID(rawValue: "/folder")
    private func app(_ name: String) -> ApplicationChoice {
        ApplicationChoice(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name)
    }
    func testIntersectionDefaultAndAlwaysOpenRequest() async throws {
        let first = app("First"), shared = app("Shared"), last = app("Last")
        let resolver = InMemoryApplicationResolver(choices: [a: [first, shared, shared], b: [shared, last]],
                                                   defaults: [a: shared, b: shared])
        let model = try await OpenWithModel.resolve(items: [a, b, a], using: resolver)
        XCTAssertEqual(model.items, [a, b]); XCTAssertEqual(model.applications, [shared])
        XCTAssertEqual(model.defaultApplication, shared); XCTAssertEqual(model.otherApplications, [])
        XCTAssertEqual(model.alwaysOpenWith(shared), AlwaysOpenWithRequest(items: [a, b], application: shared))
        XCTAssertNil(model.alwaysOpenWith(first)); XCTAssertTrue(model.offersOther)
    }
    func testDifferentDefaultsEmptyIntersectionAndMissingResolverData() async throws {
        let first = app("First"), second = app("Second")
        let resolver = InMemoryApplicationResolver(choices: [a: [first, second], b: [first, second]],
                                                   defaults: [a: first, b: second])
        let model = try await OpenWithModel.resolve(items: [a, b], using: resolver)
        XCTAssertNil(model.defaultApplication); XCTAssertEqual(model.otherApplications, [first, second])
        let missing = try await OpenWithModel.resolve(items: [a, b], using: InMemoryApplicationResolver(choices: [a: [first]]))
        XCTAssertEqual(missing.applications, []); XCTAssertTrue(missing.offersOther)
        let empty = try await OpenWithModel.resolve(items: [], using: resolver)
        XCTAssertFalse(empty.offersOther); XCTAssertNil(empty.alwaysOpenWith(first))
    }
    func testDefaultFirstDeduplicationAndTenAppMenuLimit() {
        let apps = (0..<12).map { app("App\($0)") }
        let model = OpenWithModel(items: [a], defaultApplication: apps[11], applications: apps + [apps[0]])
        XCTAssertEqual(model.applications.count, 12); XCTAssertEqual(model.menuApplications.count, 10)
        XCTAssertEqual(model.menuApplications.first, apps[11]); XCTAssertEqual(model.otherApplications.count, 11)
        let invalidDefault = OpenWithModel(items: [a], defaultApplication: app("Absent"), applications: apps)
        XCTAssertNil(invalidDefault.defaultApplication)
        let empty = OpenWithModel(items: [], defaultApplication: apps[0], applications: apps)
        XCTAssertEqual(empty.applications, []); XCTAssertNil(empty.defaultApplication)
    }
    func testResolverErrorsPropagate() async {
        struct FailingResolver: ApplicationResolving {
            func applications(for item: ItemID) async throws -> [ApplicationChoice] { throw CocoaError(.fileReadNoPermission) }
            func defaultApplication(for item: ItemID) async throws -> ApplicationChoice? { nil }
        }
        do {
            _ = try await OpenWithModel.resolve(items: [a], using: FailingResolver())
            XCTFail("Expected lookup failure")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission) }
    }
}
