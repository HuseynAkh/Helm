// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore
import HelmSearch

final class SavedSearchOpenPlanTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/saved/Project.savedSearch")
    func testEditableCriteriaOnly() throws {
        let request = SearchRequest(text: "", scope: .currentFolder(URL(fileURLWithPath: "/work")), filters: [.tag("Project")])
        let plan = SavedSearchOpenPlan(definitionURL: url, data: try SavedSearchCodec.encode(SavedSearchDocument(name: "Project", request: request)))
        XCTAssertEqual(plan.searchRequest, request)
        guard case .editable = plan.content else { return XCTFail("Expected editable document") }
    }
    func testOpaqueNeverSearches() throws {
        let document = try FinderSavedSearchDocument(rawQuery: "*", searchScopes: ["/work"])
        let plan = SavedSearchOpenPlan(definitionURL: url, data: FinderSavedSearchCodec.encode(document))
        XCTAssertNil(plan.searchRequest)
        guard case .opaque = plan.content else { return XCTFail("Expected opaque document") }
    }
    func testMalformedNeverSearches() { let plan = SavedSearchOpenPlan(definitionURL: url, data: Data("garbage".utf8)); XCTAssertNil(plan.searchRequest); guard case .rejected = plan.content else { return XCTFail("Expected rejection") } }
    func testEmptyDefinitionEditableButNotSearchable() throws {
        let plan = SavedSearchOpenPlan(definitionURL: url, data: try SavedSearchCodec.encode(SavedSearchDocument(name: "Empty", request: SearchRequest(text: ""))))
        XCTAssertNil(plan.searchRequest); guard case .editable = plan.content else { return XCTFail("Expected editor") }
    }
    func testQuotedEmptyCannotBroaden() throws {
        let plan = SavedSearchOpenPlan(definitionURL: url, data: try SavedSearchCodec.encode(SavedSearchDocument(name: "Empty", request: SearchRequest(text: "\"\""))))
        XCTAssertNil(plan.searchRequest)
    }
    func testRemovalTargetsDefinitionOnly() throws {
        let request = SearchRequest(text: "x", scope: .currentFolder(URL(fileURLWithPath: "/results")))
        let plan = SavedSearchOpenPlan(definitionURL: url, data: try SavedSearchCodec.encode(SavedSearchDocument(name: "x", request: request)))
        XCTAssertEqual(plan.definitionRemovalIntent, url); XCTAssertEqual(plan.searchRequest, request)
    }
    func testRemoteDefinitionRefused() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/search"))
        let plan = SavedSearchOpenPlan(definitionURL: remote, data: Data()); XCTAssertNil(plan.searchRequest); XCTAssertNil(plan.definitionRemovalIntent)
    }
    func testInvalidTypedDefinitionRefused() throws {
        let document = SavedSearchDocument(name: "bad", request: SearchRequest(text: "", filters: [.tag("")]))
        let plan = SavedSearchOpenPlan(definitionURL: url, data: try JSONEncoder().encode(document)); XCTAssertNil(plan.searchRequest)
        guard case .rejected = plan.content else { return XCTFail("Expected rejection") }
    }
}
