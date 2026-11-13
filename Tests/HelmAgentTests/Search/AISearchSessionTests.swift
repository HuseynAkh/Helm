import XCTest
import HelmCore
@testable import HelmAgent

/// The two questions of an AI search, asked of the scripted model: how a plan is cut down to Helm's limits, what a
/// ranking keeps, and that neither question offers a tool or sends more than it should.
final class AISearchSessionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }
    private let today = Date(timeIntervalSince1970: 1_794_000_000)

    private func client(plan: String? = nil, rank: String? = nil, isLocal: Bool = false) throws -> ScriptedModelClient {
        let script = AgentScript(rules: [], searchPlan: try plan.map { try AgentJSON(data: Data($0.utf8)) },
                                 searchRank: try rank.map { try AgentJSON(data: Data($0.utf8)) })
        return ScriptedModelClient(script: script, isLocal: isLocal)
    }

    private func query(_ fields: String) -> String {
        // Every field the schema requires, with the ones a test sets filled in.
        var all: [String: String] = ["name_all": "[]", "name_any": "[]", "content_all": "[]", "folder_any": "[]",
                                     "kinds": "[]", "extensions": "[]", "date_field": "\"none\"", "date_from": "\"\"",
                                     "date_to": "\"\"", "size_min_bytes": "0", "size_max_bytes": "0"]
        for part in fields.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            all[pair[0]] = pair[1]
        }
        return "{" + all.keys.sorted().map { "\"\($0)\": \(all[$0]!)" }.joined(separator: ", ") + "}"
    }

    private func plan(_ queries: [String], sort: String = "relevance") -> String {
        "{\"sort\": \"\(sort)\", \"queries\": [\(queries.joined(separator: ", "))]}"
    }

    // MARK: Planning

    func testAPlanKeepsSixQueriesAndEightWordsAField() async throws {
        let words = (1...10).map { "\"word\($0)\"" }.joined(separator: ", ")
        let queries = (1...8).map { query("name_any = [\"q\($0)\", \(words)]") }
        let model = try client(plan: plan(queries))
        let session = AISearchSession(client: model, calendar: calendar)
        let result = try await session.plan(request: "find my word files", scopeLabel: "Downloads", today: today, languageCode: "en")
        XCTAssertEqual(result.queries.count, 6, "at most six queries")
        for (index, planned) in result.queries.enumerated() {
            XCTAssertEqual(planned.nameAny.count, 8, "at most eight words a field")
            XCTAssertEqual(planned.nameAny, ["q\(index + 1)"] + (1...7).map { "word\($0)" }, "the strictest six, in order")
        }
    }

    func testAWordWithASpaceOrAWildcardIsDropped() async throws {
        let model = try client(plan: plan([query("name_any = [\"two words\", \"ok\", \"in*voice\", \"a\\\"quote\"]")]))
        let session = AISearchSession(client: model, calendar: calendar)
        let result = try await session.plan(request: "ok", scopeLabel: "Home", today: today, languageCode: "en")
        XCTAssertEqual(result.queries.map(\.nameAny), [["ok"]])
    }

    func testContentWordsAreOnlyThePersonsOwn() async throws {
        let model = try client(plan: plan([query("content_all = [\"plumber\", \"receipt\", \"INVOICE\"]")]))
        let session = AISearchSession(client: model, calendar: calendar)
        let result = try await session.plan(request: "the plumber's invoice from spring", scopeLabel: "Downloads", today: today,
                                            languageCode: "en")
        XCTAssertEqual(result.queries.first?.contentAll, ["plumber", "INVOICE"],
                       "a word the request holds is kept, whatever its case; one it doesn't hold is dropped")
    }

    func testAPlanWithNoQueriesFallsBackToTheRequestsOwnWords() async throws {
        let model = try client(plan: plan([]))
        let session = AISearchSession(client: model, calendar: calendar)
        let result = try await session.plan(request: "tax return 2025", scopeLabel: "Documents", today: today, languageCode: "en")
        XCTAssertEqual(result.queries.count, 1)
        XCTAssertEqual(result.queries.first?.nameAny, ["tax", "return", "2025"])
        XCTAssertEqual(result.queries.first?.contentAll, [])
    }

    func testAPlanWhoseQueriesAskForNothingFallsBackToo() async throws {
        let model = try client(plan: plan([query("name_any = [\"has space\"]"), query("kinds = [\"spaceship\"]")]))
        let session = AISearchSession(client: model, calendar: calendar)
        let result = try await session.plan(request: "budget", scopeLabel: "Home", today: today, languageCode: "en")
        XCTAssertEqual(result.queries, [AISearchQuery(nameAny: ["budget"])])
    }

    func testKindsDatesSizesAndSortAreRead() async throws {
        let model = try client(plan: plan([query("""
            kinds = ["pdf", "pdf", "nonsense", "image"]; date_field = "modified"; date_from = "2026-03-01"; \
            date_to = "2026-06-30"; size_min_bytes = 1000; size_max_bytes = -5; extensions = [".PDF"]
            """)], sort: "newest"))
        let session = AISearchSession(client: model, calendar: calendar)
        let result = try await session.plan(request: "pdfs from spring", scopeLabel: "Home", today: today, languageCode: "en")
        let planned = try XCTUnwrap(result.queries.first)
        XCTAssertEqual(result.sort, .newest)
        XCTAssertEqual(planned.kinds, [.pdf, .image])
        XCTAssertEqual(planned.extensions, ["pdf"])
        XCTAssertEqual(planned.dateField, .modified)
        XCTAssertEqual(planned.dateFrom, calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        let lastDay = calendar.date(from: DateComponents(year: 2026, month: 6, day: 30))!
        XCTAssertTrue(calendar.isDate(try XCTUnwrap(planned.dateTo), inSameDayAs: lastDay), "the last day is included")
        XCTAssertGreaterThan(try XCTUnwrap(planned.dateTo), lastDay.addingTimeInterval(86_000))
        XCTAssertEqual(planned.sizeMinBytes, 1000)
        XCTAssertEqual(planned.sizeMaxBytes, 0, "a size below zero means none")
    }

    func testAnUnreadableAnswerOrNoAnswerFails() async throws {
        let session = AISearchSession(client: try client(), calendar: calendar)
        do {
            _ = try await session.plan(request: "x", scopeLabel: "Home", today: today, languageCode: "en")
            XCTFail("a model with no answer fails")
        } catch let failure as AgentFailure {
            XCTAssertEqual(failure, .unreadable)
        }
        let wrongShape = AISearchSession(client: try client(plan: "[1, 2]"), calendar: calendar)
        do {
            _ = try await wrongShape.plan(request: "x", scopeLabel: "Home", today: today, languageCode: "en")
            XCTFail("an answer that isn't a plan fails")
        } catch let failure as AgentFailure {
            XCTAssertEqual(failure, .unreadable)
        }
    }

    func testAnAnswerWrappedInWordsIsReadFromItsFirstObject() throws {
        let answer = Data("Sure! {\"sort\": \"oldest\", \"queries\": [{\"name_any\": [\"a}b\", \"ok\"]}]} Hope that helps {".utf8)
        let plan = try AISearchSchemas.plan(from: answer, calendar: calendar)
        XCTAssertEqual(plan.sort, .oldest)
        XCTAssertEqual(plan.queries.first?.nameAny, ["a}b", "ok"], "read before clamping; the brace inside a string doesn't end it")
    }

    // MARK: Ranking

    private func rows(_ count: Int) -> [AISearchRow] {
        (1...count).map { AISearchRow(row: $0, name: "file\($0).pdf", folder: "Home / Downloads", kind: "pdf", bytes: 1200,
                                      modified: today, created: nil, cloud: $0 == 2) }
    }

    func testRankingDropsUnknownAndRepeatedRows() async throws {
        let model = try client(rank: """
            {"ranked": [{"row": 2, "why": ["name", "name", "spooky"]}, {"row": 9, "why": ["name"]}, {"row": 2, "why": ["kind"]},
                        {"row": 1, "why": []}, {"row": 0, "why": ["date"]}, {"row": 1.5, "why": ["date"]}, {"row": "3", "why": []},
                        {"row": 3, "why": ["kind", "size"]}]}
            """)
        let session = AISearchSession(client: model, calendar: calendar)
        let verdicts = try await session.rank(request: "file", rows: rows(3))
        XCTAssertEqual(verdicts, [AISearchVerdict(row: 2, why: [.name]), AISearchVerdict(row: 1, why: []),
                                  AISearchVerdict(row: 3, why: [.kind, .size])])
    }

    func testRankingKeepsTwentyAtMost() async throws {
        let ranked = (1...40).map { "{\"row\": \($0), \"why\": [\"name\"]}" }.joined(separator: ", ")
        let model = try client(rank: "{\"ranked\": [\(ranked)]}")
        let session = AISearchSession(client: model, calendar: calendar)
        let verdicts = try await session.rank(request: "file", rows: rows(40))
        XCTAssertEqual(verdicts.map(\.row), Array(1...20))
    }

    // MARK: What is sent

    func testNeitherQuestionOffersAToolAndNothingButTheTwoQuestionsIsSent() async throws {
        let model = try client(plan: plan([query("name_any = [\"invoice\"]")]), rank: "{\"ranked\": [{\"row\": 1, \"why\": [\"name\"]}]}")
        let session = AISearchSession(client: model, calendar: calendar)
        _ = try await session.plan(request: "invoice", scopeLabel: "Downloads", today: today, languageCode: "en")
        _ = try await session.rank(request: "invoice", rows: rows(2))
        XCTAssertTrue(model.sentTurns.isEmpty, "a search never starts a tool-calling turn")
        XCTAssertEqual(model.sentAsks.map(\.schemaName), ["search_plan", "search_rank"])
        for ask in model.sentAsks {
            let schema = String(decoding: ask.schema.data(), as: UTF8.self)
            XCTAssertFalse(schema.contains("\"tools\""))
            XCTAssertFalse(schema.contains("\"tool_choice\""))
            for tool in ["list_folder", "find_items", "propose_changes"] {
                XCTAssertFalse(ask.system.contains(tool) || ask.user.contains(tool) || schema.contains(tool), "\(tool) is offered")
            }
        }
        let first = model.sentAsks[0]
        XCTAssertTrue(first.user.contains("\"searching_in\":\"Downloads\""))
        XCTAssertTrue(first.user.contains("\"language\":\"en\""))
        let second = model.sentAsks[1]
        XCTAssertTrue(second.user.contains("\"name\":\"file1.pdf\""))
        XCTAssertTrue(second.user.contains("\"folder\":\"Home / Downloads\""))
        XCTAssertTrue(second.user.contains("\"cloud\":true"), "a file that isn't downloaded is marked")
    }

    func testARequestIsCutTo500Characters() async throws {
        let model = try client(plan: plan([]))
        let session = AISearchSession(client: model, calendar: calendar)
        let long = String(repeating: "a", count: 499) + "XYZ"
        _ = try await session.plan(request: long, scopeLabel: "Home", today: today, languageCode: "en")
        let sent = model.allSentText()
        XCTAssertTrue(sent.contains(String(repeating: "a", count: 499) + "X"))
        XCTAssertFalse(sent.contains("XY"), "only the first 500 characters are sent")
    }

    func testTheSchemasAreTheDesignsShape() {
        guard case .object(let plan) = AISearchSchemas.plan, case .object(let properties)? = plan["properties"],
              case .object(let queries)? = properties["queries"], case .object(let item)? = queries["items"],
              case .array(let required)? = item["required"] else { return XCTFail("the plan schema's shape") }
        XCTAssertEqual(Set(required), Set(["name_all", "name_any", "content_all", "folder_any", "kinds", "extensions",
                                            "date_field", "date_from", "date_to", "size_min_bytes", "size_max_bytes"].map(AgentJSON.string)))
        XCTAssertEqual(item["additionalProperties"], .bool(false))
        XCTAssertEqual(plan["additionalProperties"], .bool(false))
        guard case .object(let rank) = AISearchSchemas.rank, case .array(let rankRequired)? = rank["required"] else {
            return XCTFail("the rank schema's shape")
        }
        XCTAssertEqual(rankRequired, [.string("ranked")])
    }

    func testLimitsByWhereTheModelRuns() {
        XCTAssertEqual(AISearchSession.maxRows(isLocal: false), 60)
        XCTAssertEqual(AISearchSession.maxRows(isLocal: true), 30)
        XCTAssertEqual(AISearchSession.callSeconds(isLocal: false), 20)
        XCTAssertEqual(AISearchSession.callSeconds(isLocal: true), 60)
        XCTAssertEqual(AISearchSession.requestCharacters, 500)
    }
}
