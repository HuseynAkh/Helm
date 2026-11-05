// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class CloudPolicyTests: XCTestCase {
    func testAvailabilityPurposeCapabilityTable() {
        for availability in [CloudAvailability.local, .evicted, .downloading, .unknown] {
            for purpose in CloudAccessPurpose.allCases {
                for materialize in [false, true] {
                    for evict in [false, true] {
                        let entry = FileEntry(url: URL(fileURLWithPath: "/cloud/file"), cloudAvailability: availability)
                        let capability = CloudCapabilities(canMaterialize: materialize, canEvict: evict)
                        let expected: CloudActionPlan
                        switch (purpose, availability) {
                        case (.listing, _): expected = .metadataOnly
                        case (.thumbnail, .local): expected = .useLocalContent
                        case (.thumbnail, _): expected = .suppressThumbnail
                        case (_, .local): expected = .useLocalContent
                        case (_, .unknown): expected = .unsupported
                        case (_, .evicted): expected = materialize ? .requestExplicitMaterialization : .unsupported
                        case (_, .downloading): expected = materialize ? .awaitMaterialization : .unsupported
                        }
                        XCTAssertEqual(CloudActionPlan.build(entry: entry, purpose: purpose, capabilities: capability), expected)
                        XCTAssertEqual(entry.cloudAvailability, availability)
                        for explicit in [false, true] {
                            XCTAssertEqual(CloudActionPlan.eviction(entry: entry, explicitlyRequested: explicit,
                                capabilities: capability), explicit && evict && availability == .local
                                ? .requestExplicitEviction : .unsupported)
                        }
                    }
                }
            }
        }
    }

    func testUnsupportedProviderAndUnknownStayUnknown() {
        for availability in [CloudAvailability.unknown, .evicted, .downloading] {
            let entry = FileEntry(url: URL(fileURLWithPath: "/third-party/file"), cloudAvailability: availability)
            XCTAssertEqual(CloudActionPlan.build(entry: entry, purpose: .explicitOpen,
                capabilities: CloudCapabilities()), .unsupported)
            XCTAssertEqual(entry.cloudAvailability, availability)
        }
    }

    func testRejectsRemoteAndDecoratedURLs() throws {
        for value in ["https://example.com/a", "file://server/a", "file:///a?query", "file:///a#fragment"] {
            let entry = FileEntry(url: try XCTUnwrap(URL(string: value)), cloudAvailability: .local)
            for purpose in CloudAccessPurpose.allCases {
                XCTAssertEqual(CloudActionPlan.build(entry: entry, purpose: purpose,
                    capabilities: CloudCapabilities(canMaterialize: true, canEvict: true)), .unsupported)
            }
            XCTAssertEqual(CloudActionPlan.eviction(entry: entry, explicitlyRequested: true,
                capabilities: CloudCapabilities(canEvict: true)), .unsupported)
        }
    }

    func testProgressGenerationAndCompletionAreSingleUse() throws {
        var state = CloudRequestState()
        let item = ItemID(rawValue: "/a")
        let first = try XCTUnwrap(state.begin(itemID: item, plan: .requestExplicitMaterialization))
        XCTAssertTrue(state.updateProgress(requestID: first, fraction: 0.4))
        for invalid in [Double.nan, .infinity, -0.1, 1.1, 0.2] {
            XCTAssertFalse(state.updateProgress(requestID: first, fraction: invalid))
        }
        let second = try XCTUnwrap(state.begin(itemID: ItemID(rawValue: "/b"), plan: .awaitMaterialization))
        let third = try XCTUnwrap(state.begin(itemID: item, plan: .requestExplicitMaterialization))
        XCTAssertNotEqual(first, third)
        XCTAssertFalse(state.complete(requestID: first))
        XCTAssertFalse(state.updateProgress(requestID: second, fraction: 1))
        XCTAssertNil(state.progress)
        XCTAssertTrue(state.updateProgress(requestID: third, fraction: 1))
        XCTAssertEqual(state.phase, .awaiting)
        XCTAssertTrue(state.complete(requestID: third))
        XCTAssertFalse(state.complete(requestID: third, failure: "late"))
        XCTAssertEqual(state.phase, .providerReportedCompletion)
    }

    func testCancellationAndFailureDoNotClaimTransferCancellation() throws {
        var state = CloudRequestState()
        state.cancel()
        XCTAssertEqual(state.phase, .idle)
        for plan in [CloudActionPlan.metadataOnly, .unsupported, .useLocalContent, .suppressThumbnail] {
            XCTAssertNil(state.begin(itemID: ItemID(rawValue: "/a"), plan: plan))
        }
        let id = try XCTUnwrap(state.begin(itemID: ItemID(rawValue: "/a"), plan: .requestExplicitEviction))
        state.cancel()
        XCTAssertFalse(state.complete(requestID: id))
        XCTAssertFalse(state.updateProgress(requestID: id, fraction: 1))
        XCTAssertEqual(state.phase, .cancelled)
        let next = try XCTUnwrap(state.begin(itemID: ItemID(rawValue: "/a"), plan: .requestExplicitEviction))
        XCTAssertTrue(state.complete(requestID: next, failure: "provider refused"))
        state.cancel()
        XCTAssertEqual(state.phase, .failed("provider refused"))
    }

    func testEverySourceParticipatesInBoundaryWarning() {
        let domains: [CloudProviderDomain] = [.local, .provider("iCloud"), .provider("third-party"), .unknown]
        for destination in domains {
            XCTAssertEqual(CloudMoveWarning.build(sources: [], destination: destination), .none)
            for first in domains {
                for second in domains {
                    let expected: CloudMoveWarning = destination == .unknown || first == .unknown || second == .unknown
                        ? .confirmUnknownBoundary : first != destination || second != destination ? .confirmProviderBoundary : .none
                    XCTAssertEqual(CloudMoveWarning.build(sources: [first, second], destination: destination), expected)
                }
            }
        }
    }
}
