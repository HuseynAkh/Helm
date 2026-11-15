import Foundation
import HelmCore

/// A model that answers from an `AgentScript` and keeps everything it was sent. It makes no connection, so a
/// fixture run and a test can go through a whole request, tools and plan included, with the network denied.
///
/// Its own history items are plain: a user turn is `{"role":"user","results":[…],"text":…}` and a model turn is
/// `{"role":"model","text":…,"calls":[…]}`. Which turn of a rule comes next is read from the history it is
/// handed, so the client keeps no place of its own and two windows can share one.
/// All reads and writes of what it keeps hold the lock.
public final class ScriptedModelClient: AgentModelClient, @unchecked Sendable {
    public let providerName: String
    public let destination: String
    public let isLocal: Bool

    private let lock = NSLock()
    private var script: AgentScript
    private var turns: [AgentTurnInput] = []
    private var asks: [AgentStructuredAsk] = []
    private var listFailure: AgentFailure?

    public init(script: AgentScript = .builtIn, providerName: String = "Claude", destination: String = "Claude", isLocal: Bool = false) {
        self.script = script; self.providerName = providerName; self.destination = destination; self.isLocal = isLocal
    }

    /// Takes a new script from the bytes of a script file. The caller gets the bytes from the file; this module
    /// never looks at a file itself. Throws for bytes that aren't a script, and the script in use stays.
    public func load(_ data: Data) throws {
        try AgentJSON.checkDepth(of: data)
        let loaded = try JSONDecoder().decode(AgentScript.self, from: data)
        locked { script = loaded }
    }

    /// When set, asking for the models throws this.
    public var modelsFailure: AgentFailure? {
        get { locked { listFailure } }
        set { locked { listFailure = newValue } }
    }

    /// Every model turn that was asked for, in order.
    public var sentTurns: [AgentTurnInput] { locked { turns } }
    /// Every structured question that was asked, in order.
    public var sentAsks: [AgentStructuredAsk] { locked { asks } }

    /// Everything a real client would have put on the wire, as one text: for each turn the system prompt, the tools
    /// and the history, and for each structured question its two prompts and its schema. Each piece of JSON is
    /// there as it would be sent, and every string inside it is there again as plain text, a tool result's own JSON
    /// included, so a name or a path can be looked for however it was escaped.
    public func allSentText() -> String {
        let (turns, asks) = locked { (self.turns, self.asks) }
        var lines: [String] = []
        for turn in turns {
            lines.append(turn.system)
            for tool in turn.tools {
                lines += [tool.name, tool.description]
                Self.spell(tool.schema, into: &lines)
            }
            for item in turn.history { Self.spell(item, into: &lines) }
        }
        for ask in asks {
            lines += [ask.system, ask.user, ask.schemaName]
            Self.spell(ask.schema, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: AgentModelClient

    public func turn(_ input: AgentTurnInput) -> AsyncThrowingStream<AgentModelEvent, Error> {
        let script = locked { () -> AgentScript in
            turns.append(input)
            return self.script
        }
        let answer = Self.answer(to: input.history, script: script)
        return AsyncThrowingStream { continuation in
            switch answer {
            case .failure(let failure):
                continuation.finish(throwing: failure)
            case .success(let turn):
                if let text = turn.text, !text.isEmpty { continuation.yield(.text(text)) }
                for call in turn.calls { continuation.yield(.toolStarted(name: call.name)) }
                continuation.yield(.finished(AgentTurnResult(rawItems: [turn.item], calls: turn.calls, stop: turn.stop)))
                continuation.finish()
            }
        }
    }

    public func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] {
        var item: [String: AgentJSON] = [Keys.role: .string(Keys.user)]
        if !toolResults.isEmpty {
            item[Keys.results] = .array(toolResults.map { result in
                .object([Keys.id: .string(result.callID), Keys.name: .string(result.name),
                         Keys.json: .string(result.json), Keys.error: .bool(result.isError)])
            })
        }
        if let text { item[Keys.text] = .string(text) }
        return [.object(item)]
    }

    /// The script's search plan for a question named "search_plan" and its ranking for "search_rank". A question of
    /// any other name, or one the script has no answer for, fails as unreadable.
    public func structured(_ ask: AgentStructuredAsk) async throws -> Data {
        let script = locked { () -> AgentScript in
            asks.append(ask)
            return self.script
        }
        let answer: AgentJSON?
        switch ask.schemaName {
        case Self.searchPlanName: answer = script.searchPlan
        case Self.searchRankName: answer = script.searchRank
        default: answer = nil
        }
        guard let answer else { throw AgentFailure.unreadable }
        return answer.data()
    }

    public func models() async throws -> [AgentModelInfo] {
        let (failure, names) = locked { (listFailure, script.models) }
        if let failure { throw failure }
        return names.compactMap(AgentModelInfo.init(id:))
    }

    // MARK: Answering

    static let searchPlanName = "search_plan"
    static let searchRankName = "search_rank"

    private enum Keys {
        static let role = "role", user = "user", model = "model", text = "text", results = "results"
        static let calls = "calls", id = "id", name = "name", json = "json", error = "error", args = "args"
    }

    private struct ScriptedTurn {
        var text: String?
        var calls: [AgentToolCall]
        var stop: AgentStop
        var item: AgentJSON
    }

    /// The next model turn for a history: the rule is the first that the person's last message matches, and the
    /// turn is the rule's next one after the model turns already taken since that message. Helm's ask for a plan
    /// (`AgentPrompt.planNow`) is not a message, so the rule goes on to its next turn after it.
    private static func answer(to history: [AgentJSON], script: AgentScript) -> Result<ScriptedTurn, AgentFailure> {
        let lastMessage = history.lastIndex {
            $0[Keys.role]?.stringValue == Keys.user && $0[Keys.text] != nil && $0[Keys.text]?.stringValue != AgentPrompt.planNow
        }
        let said = lastMessage.flatMap { history[$0][Keys.text]?.stringValue } ?? ""
        let taken = history[(lastMessage ?? history.startIndex)...].filter { $0[Keys.role]?.stringValue == Keys.model }.count
        let words = message(in: said).lowercased()
        guard let rule = script.rules.first(where: { $0.when == "*" || words.contains($0.when.lowercased()) }) else {
            return .success(closing(text: nil))
        }
        guard taken < rule.turns.count else {
            if let failure = rule.failure.flatMap(AgentFailure.init(rawValue:)) { return .failure(failure) }
            return .success(closing(text: nil))
        }
        let turn = rule.turns[taken]
        let callsBefore = history.reduce(0) { $0 + ($1[Keys.calls]?.arrayValue?.count ?? 0) }
        var calls: [AgentToolCall] = [], items: [AgentJSON] = []
        for (offset, call) in (turn.calls ?? []).enumerated() {
            let id = "call_\(callsBefore + offset + 1)"
            let arguments = filled(call.args, history: history)
            calls.append(AgentToolCall(id: id, name: call.name, arguments: arguments.data()))
            items.append(.object([Keys.id: .string(id), Keys.name: .string(call.name), Keys.args: arguments]))
        }
        let stop: AgentStop
        switch turn.stop {
        case "refusal": stop = .refusal
        case "max_tokens": stop = .maxTokens
        case "content_filter": stop = .contentFilter
        default: stop = calls.isEmpty ? .endTurn : .toolUse
        }
        var item: [String: AgentJSON] = [Keys.role: .string(Keys.model)]
        if let text = turn.text { item[Keys.text] = .string(text) }
        if !items.isEmpty { item[Keys.calls] = .array(items) }
        return .success(ScriptedTurn(text: turn.text, calls: calls, stop: stop, item: .object(item)))
    }

    /// A turn that says nothing more and ends the request: what a script answers once it has nothing left to say.
    private static func closing(text: String?) -> ScriptedTurn {
        ScriptedTurn(text: text, calls: [], stop: .endTurn, item: .object([Keys.role: .string(Keys.model)]))
    }

    /// The person's own words in a user turn's text. Helm's note about the folders comes first, on lines that start
    /// with "[Helm]"; a rule is matched against what follows it. Text that is nothing but such lines is matched whole.
    private static func message(in text: String) -> String {
        let words = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix(noteMark) }
            .joined(separator: "\n")
        return words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : words
    }

    private static let noteMark = "[Helm]"
    private static let rootMark = "@root"
    private static let nameMark = "@name:"

    /// A call's arguments with `@root` and `@name:<file>` filled in from the history. A mark that can't be filled
    /// in is left as it is, which the tool then refuses as an id it never issued.
    private static func filled(_ json: AgentJSON, history: [AgentJSON]) -> AgentJSON {
        switch json {
        case .string(let text):
            if text == rootMark { return shownRoot(in: history).map(AgentJSON.string) ?? json }
            if text.hasPrefix(nameMark) { return id(ofItemNamed: String(text.dropFirst(nameMark.count)), in: history).map(AgentJSON.string) ?? json }
            return json
        case .array(let values): return .array(values.map { filled($0, history: history) })
        case .object(let members): return .object(members.mapValues { filled($0, history: history) })
        case .null, .bool, .number: return json
        }
    }

    /// The alias of the folder on show, from the newest note about the folders: the one marked "(on show)", or
    /// failing that the first one listed.
    private static func shownRoot(in history: [AgentJSON]) -> String? {
        for item in history.reversed() {
            guard let text = item[Keys.text]?.stringValue else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix(noteMark) {
                guard let start = line.range(of: "Folders:") else { continue }
                let folders = line[start.upperBound...].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                let shown = folders.first { $0.contains("(on show)") } ?? folders.first
                if let alias = shown?.split(separator: " ").first { return String(alias) }
            }
        }
        return nil
    }

    /// The id of the item with this name in the tool results the client was sent, newest result first. A name in a
    /// result is escaped, so the name is looked for both as written and as escaped.
    private static func id(ofItemNamed name: String, in history: [AgentJSON]) -> String? {
        let names: Set<String> = [name, AgentTextEscaper.escape(name)]
        for item in history.reversed() {
            for result in (item[Keys.results]?.arrayValue ?? []).reversed() {
                guard let text = result[Keys.json]?.stringValue, let json = AgentJSON(jsonText: text) else { continue }
                if let id = id(ofItemNamed: names, in: json) { return id }
            }
        }
        return nil
    }

    private static func id(ofItemNamed names: Set<String>, in json: AgentJSON) -> String? {
        switch json {
        case .object(let members):
            if let name = members[Keys.name]?.stringValue, names.contains(name), let id = members[Keys.id]?.stringValue { return id }
            for key in members.keys.sorted() {
                if let member = members[key], let id = id(ofItemNamed: names, in: member) { return id }
            }
            return nil
        case .array(let values):
            for value in values {
                if let id = id(ofItemNamed: names, in: value) { return id }
            }
            return nil
        case .null, .bool, .number, .string: return nil
        }
    }

    /// Adds a value's JSON text, and then every string in it as plain text. A string that is JSON itself, as a tool
    /// result is, is spelled out the same way.
    private static func spell(_ json: AgentJSON, into lines: inout [String]) {
        lines.append(String(decoding: json.data(), as: UTF8.self))
        spellStrings(of: json, into: &lines)
    }

    private static func spellStrings(of json: AgentJSON, into lines: inout [String]) {
        switch json {
        case .string(let text):
            lines.append(text)
            if let inner = AgentJSON(jsonText: text) { spellStrings(of: inner, into: &lines) }
        case .array(let values):
            for value in values { spellStrings(of: value, into: &lines) }
        case .object(let members):
            for key in members.keys.sorted() {
                lines.append(key)
                if let member = members[key] { spellStrings(of: member, into: &lines) }
            }
        case .null, .bool, .number: break
        }
    }

    private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
