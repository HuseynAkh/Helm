import XCTest
import HelmCore
@testable import HelmAgent

/// The model that answers from a script: which rule answers a message, how a rule's turns follow each other, how
/// its marks are filled in, and that everything it was sent can be read back.
final class ScriptedModelClientTests: XCTestCase {
    /// The script file as the design writes it out.
    private let scriptText = """
    {"rules": [
      {"when": "organize", "turns": [
        {"calls": [{"name": "list_folder", "args": {"folder": "@root", "depth": 1, "after": ""}}]},
        {"text": "Images go into a new Images folder.",
         "calls": [{"name": "propose_changes", "args": {
            "new_folders": [{"key": "n1", "parent": "@root", "name": "Images"}],
            "new_files": [],
            "moves": [{"items": ["@name:a.png", "@name:b.png"], "all_in": "", "to": "n1"}],
            "copies": [], "renames": [], "trash": []}}]}]},
      {"when": "broken", "turns": [], "failure": "unreachable"},
      {"when": "*", "turns": [{"text": "I can organize, move and copy files in these folders."}]}],
     "searchPlan": {"sort": "relevance", "queries": []},
     "searchRank": {"ranked": [{"row": 1, "why": ["name"]}]},
     "models": ["scripted-1"]}
    """

    private let note = "[Helm] Folders: r1 this_mac (on show); r2 cloud \"Google Drive\" syncs shared=unknown."
    private let listing = """
    {"source": "folder_listing", "folder": "r1", "root": "r1", "name": "Home", "place": "this_mac",
     "items": [{"id": "f12", "in": "r1", "name": "a.png", "kind": "image", "bytes": 410000, "modified": "2026-03-14"},
               {"id": "d14", "in": "r1", "name": "Old", "kind": "folder", "modified": "2026-01-02"},
               {"id": "f13", "in": "r1", "name": "b.png", "kind": "image", "bytes": 88000, "modified": "2026-10-02"}],
     "more": 0, "not_loaded": 0, "partial": "none"}
    """

    private struct Played {
        var texts: [String] = []
        var tools: [String] = []
        var result: AgentTurnResult
    }

    private func scripted() throws -> ScriptedModelClient {
        let client = ScriptedModelClient()
        try client.load(Data(scriptText.utf8))
        return client
    }

    private func play(_ client: ScriptedModelClient, _ history: [AgentJSON]) async throws -> Played {
        var texts: [String] = [], tools: [String] = [], result: AgentTurnResult?
        for try await event in client.turn(AgentTurnInput(system: "the system prompt", tools: AgentToolCatalog.all, history: history)) {
            switch event {
            case .text(let text): texts.append(text)
            case .toolStarted(let name): tools.append(name)
            case .finished(let finished):
                XCTAssertNil(result, "one finish a turn")
                result = finished
            }
        }
        return Played(texts: texts, tools: tools, result: try XCTUnwrap(result, "the last event is the finish"))
    }

    private func arguments(_ call: AgentToolCall) throws -> AgentJSON { try AgentJSON(data: call.arguments) }

    private func says(_ client: ScriptedModelClient, _ words: String) -> [AgentJSON] {
        client.userItems(text: note + "\n\n" + words, toolResults: [])
    }

    // MARK: Rules

    func testTheBuiltInScriptAnswersAnything() async throws {
        let client = ScriptedModelClient()
        XCTAssertEqual(client.providerName, "Claude")
        XCTAssertEqual(client.destination, "Claude")
        XCTAssertFalse(client.isLocal)
        for words in ["hello", "organize everything", ""] {
            let played = try await play(client, client.userItems(text: words, toolResults: []))
            XCTAssertEqual(played.texts, ["I can organize, move and copy files in these folders."], words)
            XCTAssertEqual(played.tools, [])
            XCTAssertEqual(played.result.stop, .endTurn)
            XCTAssertEqual(played.result.calls, [])
            XCTAssertEqual(played.result.rawItems.count, 1)
        }
        let local = ScriptedModelClient(providerName: "Ollama", destination: "Ollama on this Mac", isLocal: true)
        XCTAssertEqual([local.providerName, local.destination], ["Ollama", "Ollama on this Mac"])
        XCTAssertTrue(local.isLocal)
    }

    func testTheFirstRuleThatMatchesAnswers() async throws {
        let client = try scripted()
        // Without regard to case, and anywhere in the message.
        for words in ["organize", "Organize the items in r1 into folders by kind. Depth: this folder.", "please ORGANIZE these"] {
            let played = try await play(client, says(client, words))
            XCTAssertEqual(played.tools, ["list_folder"], words)
        }
        // A message that fits two rules gets the one listed first.
        let both = try await play(client, says(client, "organize the broken ones"))
        XCTAssertEqual(both.tools, ["list_folder"])
        // Anything else gets the rule that matches everything.
        let other = try await play(client, says(client, "what can you do?"))
        XCTAssertEqual(other.texts, ["I can organize, move and copy files in these folders."])
        XCTAssertEqual(other.result.stop, .endTurn)
    }

    func testARuleIsMatchedAgainstThePersonsWordsAndNotHelmsNote() async throws {
        let client = ScriptedModelClient(script: AgentScript(rules: [
            AgentScript.Rule(when: "folders", turns: [AgentScript.Turn(text: "matched the note")]),
            AgentScript.Rule(when: "*", turns: [AgentScript.Turn(text: "matched the words")])
        ]))
        // "Folders" is in Helm's note, which every message starts with.
        let played = try await play(client, says(client, "hello"))
        XCTAssertEqual(played.texts, ["matched the words"])
        let asked = try await play(client, says(client, "which folders are these?"))
        XCTAssertEqual(asked.texts, ["matched the note"])
    }

    func testAScriptWithNoRuleForAMessageSaysNothing() async throws {
        let client = ScriptedModelClient(script: AgentScript(rules: [AgentScript.Rule(when: "organize", turns: [AgentScript.Turn(text: "ok")])]))
        let played = try await play(client, says(client, "something else"))
        XCTAssertEqual(played.texts, [])
        XCTAssertEqual(played.result.stop, .endTurn)
        XCTAssertEqual(played.result.calls, [])
    }

    // MARK: Turns

    func testARulesTurnsFollowEachOtherThroughARequest() async throws {
        let client = try scripted()
        var history = says(client, "Organize the items in r1 into folders by kind. Depth: this folder.")

        // Turn one: look.
        let first = try await play(client, history)
        XCTAssertEqual(first.texts, [])
        XCTAssertEqual(first.tools, ["list_folder"])
        XCTAssertEqual(first.result.stop, .toolUse)
        let look = try XCTUnwrap(first.result.calls.first)
        XCTAssertEqual(first.result.calls.count, 1)
        XCTAssertEqual(look.name, "list_folder")
        XCTAssertEqual(try arguments(look), .object(["folder": .string("r1"), "depth": .number(1), "after": .string("")]))

        // Turn two: propose, with ids from the listing it was sent.
        history += first.result.rawItems
        history += client.userItems(text: nil, toolResults: [AgentToolResult(callID: look.id, name: look.name, json: listing)])
        let second = try await play(client, history)
        XCTAssertEqual(second.texts, ["Images go into a new Images folder."])
        XCTAssertEqual(second.tools, ["propose_changes"])
        XCTAssertEqual(second.result.stop, .toolUse)
        let propose = try XCTUnwrap(second.result.calls.first)
        XCTAssertNotEqual(propose.id, look.id)
        XCTAssertEqual(AgentProposedChanges.decodeStrictly(propose.arguments), AgentProposedChanges(
            newFolders: [.init(key: "n1", parent: "r1", name: "Images")],
            moves: [.init(items: ["f12", "f13"], allIn: "", to: "n1")],
            copies: [], renames: [], trash: []))

        // The rule has no third turn, so the model has nothing more to say.
        history += second.result.rawItems
        history += client.userItems(text: nil, toolResults: [AgentToolResult(callID: propose.id, name: propose.name, json: #"{"source":"plan","status":"dismissed"}"#)])
        let third = try await play(client, history)
        XCTAssertEqual(third.texts, [])
        XCTAssertEqual(third.tools, [])
        XCTAssertEqual(third.result.stop, .endTurn)

        // A new message starts its rule from the first turn again.
        history += third.result.rawItems
        history += says(client, "organize again")
        let again = try await play(client, history)
        XCTAssertEqual(again.tools, ["list_folder"])
        XCTAssertFalse([look.id, propose.id].contains(try XCTUnwrap(again.result.calls.first).id), "an id is never used twice")
    }

    func testTheSameHistoryAlwaysGetsTheSameTurn() async throws {
        // The client keeps no place of its own, so two windows can share it.
        let client = try scripted()
        let history = says(client, "organize")
        let one = try await play(client, history)
        let two = try await play(client, history)
        XCTAssertEqual(one.result.calls, two.result.calls)
        XCTAssertEqual(one.result.rawItems, two.result.rawItems)
        XCTAssertEqual(client.sentTurns.count, 2)
    }

    func testAFailingRuleFailsTheRequest() async throws {
        let client = try scripted()
        do {
            _ = try await play(client, says(client, "this is broken"))
            XCTFail("the turn didn't fail")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .unreachable)
        }
    }

    func testAFailureComesAfterTheRulesTurns() async throws {
        let list = AgentScript.Call(name: "list_folder", args: .object(["folder": .string("@root"), "depth": .number(1), "after": .string("")]))
        let client = ScriptedModelClient(script: AgentScript(rules: [
            AgentScript.Rule(when: "later", turns: [AgentScript.Turn(calls: [list])], failure: "rateLimited"),
            AgentScript.Rule(when: "odd", turns: [], failure: "no such failure")
        ]))
        var history = says(client, "fail later")
        let first = try await play(client, history)
        XCTAssertEqual(first.tools, ["list_folder"])
        history += first.result.rawItems
        history += client.userItems(text: nil, toolResults: [AgentToolResult(callID: first.result.calls[0].id, name: "list_folder", json: listing)])
        do {
            _ = try await play(client, history)
            XCTFail("the second turn didn't fail")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .rateLimited)
        }
        // A failure that isn't one of Helm's is no failure.
        let odd = try await play(client, says(client, "odd"))
        XCTAssertEqual(odd.result.stop, .endTurn)
    }

    func testATurnCanEndInARefusalOrOutOfRoom() async throws {
        let call = AgentScript.Call(name: "propose_changes", args: .object(["trash": .array([.string("@name:a.png")])]))
        let client = ScriptedModelClient(script: AgentScript(rules: [
            AgentScript.Rule(when: "refuse", turns: [AgentScript.Turn(text: "No.", stop: "refusal")]),
            AgentScript.Rule(when: "long", turns: [AgentScript.Turn(text: "Too much", calls: [call], stop: "max_tokens")]),
            AgentScript.Rule(when: "filter", turns: [AgentScript.Turn(stop: "content_filter")])
        ]))
        let refused = try await play(client, says(client, "refuse this"))
        XCTAssertEqual(refused.result.stop, .refusal)
        XCTAssertEqual(refused.texts, ["No."])
        // A turn cut short can still carry a call, which must then not be run.
        let cut = try await play(client, says(client, "a long one"))
        XCTAssertEqual(cut.result.stop, .maxTokens)
        XCTAssertEqual(cut.result.calls.map(\.name), ["propose_changes"])
        let filtered = try await play(client, says(client, "filter"))
        XCTAssertEqual(filtered.result.stop, .contentFilter)
    }

    // MARK: Marks

    func testRootIsTheFolderOnShow() async throws {
        let list = AgentScript.Call(name: "list_folder", args: .object(["folder": .string("@root"), "depth": .number(0), "after": .string("")]))
        let client = ScriptedModelClient(script: AgentScript(rules: [AgentScript.Rule(when: "*", turns: [AgentScript.Turn(calls: [list])])]))
        func folder(_ note: String?) async throws -> AgentJSON? {
            let text = (note.map { $0 + "\n\n" } ?? "") + "list it"
            let played = try await play(client, client.userItems(text: text, toolResults: []))
            return try arguments(played.result.calls[0])["folder"]
        }
        var answer = try await folder("[Helm] Folders: r1 this_mac; r2 cloud \"Google Drive\" syncs (on show); r3 server shared no_trash.")
        XCTAssertEqual(answer, .string("r2"))
        answer = try await folder("[Helm] Folders: r7 this_mac (on show). 12 items are selected in r7. Last plan: applied 210, skipped 4.")
        XCTAssertEqual(answer, .string("r7"))
        // With none marked, the first folder listed.
        answer = try await folder("[Helm] Folders: r4 external; r5 this_mac.")
        XCTAssertEqual(answer, .string("r4"))
        // With no note at all there is nothing to fill in, and the mark is left for the tool to refuse.
        answer = try await folder(nil)
        XCTAssertEqual(answer, .string("@root"))
    }

    func testTheNewestNoteNamesTheFolderOnShow() async throws {
        let list = AgentScript.Call(name: "list_folder", args: .object(["folder": .string("@root"), "depth": .number(1), "after": .string("")]))
        let client = ScriptedModelClient(script: AgentScript(rules: [AgentScript.Rule(when: "*", turns: [AgentScript.Turn(calls: [list])])]))
        var history = client.userItems(text: "[Helm] Folders: r1 this_mac (on show).\n\nfirst", toolResults: [])
        history += try await play(client, history).result.rawItems
        history += client.userItems(text: "[Helm] Folders: r2 this_mac (on show); r3 cloud.\n\nsecond", toolResults: [])
        let played = try await play(client, history)
        XCTAssertEqual(try arguments(played.result.calls[0])["folder"], .string("r2"))
    }

    func testANameIsFilledInFromTheResultsTheClientWasSent() async throws {
        let call = AgentScript.Call(name: "propose_changes", args: .object([
            "trash": .array([.string("@name:b.png"), .string("@name:Old"), .string("@name:missing.png"), .string("f99"), .string("@name:hid\u{202E}den.txt")])
        ]))
        // The history below holds one model turn since the message, so the calls are the rule's second turn.
        let client = ScriptedModelClient(script: AgentScript(rules: [
            AgentScript.Rule(when: "*", turns: [AgentScript.Turn(), AgentScript.Turn(calls: [call])])
        ]))
        let older = #"{"source":"folder_listing","items":[{"id":"f1","name":"b.png"}]}"#
        // A name with a hidden character is sent in its escaped form, and is found by the name as it is on the disk.
        let escaped = AgentJSON.object(["source": .string("found_items"), "items": .array([
            .object(["id": .string("f20"), "name": .string(AgentTextEscaper.escape("hid\u{202E}den.txt"))])
        ])])
        var history = client.userItems(text: note + "\n\ntrash them", toolResults: [])
        history += [.object(["role": .string("model")])]
        history += client.userItems(text: nil, toolResults: [
            AgentToolResult(callID: "call_1", name: "list_folder", json: older),
            AgentToolResult(callID: "call_2", name: "list_folder", json: listing),
            AgentToolResult(callID: "call_3", name: "find_items", json: String(decoding: escaped.data(), as: UTF8.self)),
            AgentToolResult(callID: "call_4", name: "list_folder", json: #"{"source":"error","code":"not_responding"}"#, isError: true)
        ])
        let played = try await play(client, history)
        // The newest result that holds the name wins; a name that was never listed and a plain id are left alone.
        XCTAssertEqual(try arguments(played.result.calls[0])["trash"],
                       .array([.string("f13"), .string("d14"), .string("@name:missing.png"), .string("f99"), .string("f20")]))
    }

    // MARK: What it was sent

    func testAUserTurnIsOneItemWithItsResultsAndItsText() {
        let client = ScriptedModelClient()
        let results = [AgentToolResult(callID: "call_1", name: "list_folder", json: #"{"items":[]}"#),
                       AgentToolResult(callID: "call_2", name: "find_items", json: #"{"source":"error","code":"hidden"}"#, isError: true)]
        XCTAssertEqual(client.userItems(text: "hello", toolResults: results), [.object([
            "role": .string("user"), "text": .string("hello"),
            "results": .array([
                .object(["id": .string("call_1"), "name": .string("list_folder"), "json": .string(#"{"items":[]}"#), "error": .bool(false)]),
                .object(["id": .string("call_2"), "name": .string("find_items"), "json": .string(#"{"source":"error","code":"hidden"}"#), "error": .bool(true)])
            ])
        ])])
        XCTAssertEqual(client.userItems(text: "hello", toolResults: []), [.object(["role": .string("user"), "text": .string("hello")])])
        XCTAssertEqual(client.userItems(text: nil, toolResults: [results[0]]).first?["text"], nil)
    }

    func testEverythingSentIsKept() async throws {
        let client = try scripted()
        XCTAssertEqual(client.sentTurns.count, 0)
        XCTAssertEqual(client.allSentText(), "")
        var history = says(client, "organize /home/helm/Tax 2026")
        let first = try await play(client, history)
        history += first.result.rawItems
        let awkward = AgentJSON.object(["items": .array([.object(["id": .string("f1"), "name": .string("me@example.com's \"notes\" \\ draft.txt")])])])
        history += client.userItems(text: nil, toolResults: [AgentToolResult(callID: first.result.calls[0].id, name: "list_folder",
                                                                              json: String(decoding: awkward.data(), as: UTF8.self))])
        _ = try await play(client, history)
        _ = try await client.structured(AgentStructuredAsk(system: "plan a search", user: "the plumber's invoice", schemaName: "search_plan",
                                                           schema: .object(["type": .string("object")])))

        XCTAssertEqual(client.sentTurns.count, 2)
        XCTAssertEqual(client.sentTurns.map(\.system), ["the system prompt", "the system prompt"])
        XCTAssertEqual(client.sentTurns[1].history, history)
        XCTAssertEqual(client.sentTurns[0].tools, AgentToolCatalog.all)
        XCTAssertEqual(client.sentAsks.map(\.user), ["the plumber's invoice"])

        let sent = client.allSentText()
        for expected in ["the system prompt", "list_folder", "Nothing changes until they press Apply.", "[Helm] Folders: r1 this_mac (on show)",
                         "organize /home/helm/Tax 2026", "me@example.com's \"notes\" \\ draft.txt", "plan a search", "the plumber's invoice",
                         "search_plan", "additionalProperties"] {
            XCTAssertTrue(sent.contains(expected), expected)
        }
        // Something that never went in isn't there, so a search for it means what it says.
        XCTAssertFalse(sent.contains("/Users/"))
        XCTAssertFalse(sent.contains("secret.txt"))
    }

    // MARK: Structured answers and models

    func testSearchQuestionsGetTheScriptsAnswers() async throws {
        let client = try scripted()
        func ask(_ name: String) async throws -> AgentJSON {
            let data = try await client.structured(AgentStructuredAsk(system: "s", user: "u", schemaName: name, schema: .object([:])))
            return try AgentJSON(data: data)
        }
        var answer = try await ask("search_plan")
        XCTAssertEqual(answer, .object(["sort": .string("relevance"), "queries": .array([])]))
        answer = try await ask("search_rank")
        XCTAssertEqual(answer, .object(["ranked": .array([.object(["row": .number(1), "why": .array([.string("name")])])])]))
        XCTAssertEqual(client.sentAsks.map(\.schemaName), ["search_plan", "search_rank"])
        XCTAssertEqual(client.sentTurns.count, 0, "a search question is not a turn, and carries no tools")

        do {
            _ = try await ask("something_else")
            XCTFail("an unknown question was answered")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .unreadable)
        }
        // A script with no answer fails the question, which is how a failed search is scripted.
        let silent = ScriptedModelClient(script: AgentScript(rules: []))
        do {
            _ = try await silent.structured(AgentStructuredAsk(system: "s", user: "u", schemaName: "search_plan", schema: .object([:])))
            XCTFail("a script with no plan answered")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .unreadable)
        }
    }

    func testTheModelsAreTheScripts() async throws {
        let client = ScriptedModelClient(script: AgentScript(rules: [], models: ["scripted-1", "two words", "", "scripted-2:latest"]))
        var models = try await client.models()
        XCTAssertEqual(models.map(\.id), ["scripted-1", "scripted-2:latest"], "a name no provider could list is dropped")
        models = try await ScriptedModelClient().models()
        XCTAssertEqual(models.map(\.id), ["scripted-1"])

        XCTAssertNil(client.modelsFailure)
        client.modelsFailure = .notRunning
        XCTAssertEqual(client.modelsFailure, .notRunning)
        do {
            _ = try await client.models()
            XCTFail("the list didn't fail")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .notRunning)
        }
        client.modelsFailure = nil
        models = try await client.models()
        XCTAssertEqual(models.count, 2)
    }

    // MARK: Script files

    func testTheScriptFileIsRead() throws {
        let script = try JSONDecoder().decode(AgentScript.self, from: Data(scriptText.utf8))
        XCTAssertEqual(script.rules.map(\.when), ["organize", "broken", "*"])
        XCTAssertEqual(script.rules[0].turns.count, 2)
        XCTAssertEqual(script.rules[0].turns[0], AgentScript.Turn(calls: [AgentScript.Call(
            name: "list_folder", args: .object(["folder": .string("@root"), "depth": .number(1), "after": .string("")]))]))
        XCTAssertEqual(script.rules[0].turns[1].text, "Images go into a new Images folder.")
        XCTAssertEqual(script.rules[1], AgentScript.Rule(when: "broken", turns: [], failure: "unreachable"))
        XCTAssertEqual(script.rules[2], AgentScript.Rule(when: "*", turns: [AgentScript.Turn(text: "I can organize, move and copy files in these folders.")]))
        XCTAssertEqual(script.searchPlan, .object(["sort": .string("relevance"), "queries": .array([])]))
        XCTAssertEqual(script.models, ["scripted-1"])
        // What is written out is read back the same.
        XCTAssertEqual(try JSONDecoder().decode(AgentScript.self, from: JSONEncoder().encode(script)), script)
    }

    func testAScriptFileMayLeaveThingsOut() throws {
        let short = try JSONDecoder().decode(AgentScript.self, from: Data(#"{"rules": [{"when": "x"}, {"when": "y", "failure": "timedOut"}]}"#.utf8))
        XCTAssertEqual(short, AgentScript(rules: [AgentScript.Rule(when: "x"), AgentScript.Rule(when: "y", failure: "timedOut")]))
        XCTAssertEqual(short.models, ["scripted-1"])
        XCTAssertNil(short.searchPlan)
        XCTAssertNil(short.searchRank)
        XCTAssertEqual(try JSONDecoder().decode(AgentScript.self, from: Data("{}".utf8)), AgentScript(rules: []))
        XCTAssertEqual(AgentScript.builtIn.rules.map(\.when), ["*"])
        XCTAssertNotNil(AgentScript.builtIn.searchPlan)
        XCTAssertNotNil(AgentScript.builtIn.searchRank)
        XCTAssertEqual(AgentScript.builtIn.models, ["scripted-1"])
    }

    func testBytesThatAreNotAScriptLeaveTheOldOneInUse() async throws {
        let client = try scripted()
        for bad in ["", "nope", "[1, 2]", #"{"rules": "none"}"#, #"{"rules": [{"turns": []}]}"#] {
            XCTAssertThrowsError(try client.load(Data(bad.utf8)), bad)
        }
        XCTAssertThrowsError(try client.load(Data(String(repeating: "[", count: 40).utf8))) { XCTAssertEqual($0 as? AgentJSONError, .tooDeep) }
        let played = try await play(client, says(client, "organize"))
        XCTAssertEqual(played.tools, ["list_folder"], "the script that was loaded before still answers")
    }
}
