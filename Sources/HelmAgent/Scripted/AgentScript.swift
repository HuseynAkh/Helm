import Foundation

/// What a scripted model says, so fixture runs and tests have a model that needs no network and always answers the
/// same way. A script is a JSON file of this shape:
///
/// ```json
/// {"rules": [
///   {"when": "organize", "turns": [
///     {"calls": [{"name": "list_folder", "args": {"folder": "@root", "depth": 1, "after": ""}}]},
///     {"text": "Images go into a new Images folder.",
///      "calls": [{"name": "propose_changes", "args": {
///         "new_folders": [{"key": "n1", "parent": "@root", "name": "Images"}],
///         "moves": [{"items": ["@name:a.png"], "all_in": "", "to": "n1"}],
///         "copies": [], "renames": [], "trash": []}}]}]},
///   {"when": "broken", "turns": [], "failure": "unreachable"},
///   {"when": "*", "turns": [{"text": "I can organize, move and copy files in these folders."}]}],
///  "searchPlan": {"sort": "relevance", "queries": []},
///  "searchRank": {"ranked": [{"row": 1, "why": ["name"]}]},
///  "models": ["scripted-1"]}
/// ```
///
/// The first rule whose `when` is in the person's message answers it, without regard to case; `*` is in every
/// message. Each of a rule's turns is one model turn of the request. In a call's arguments `@root` stands for the
/// folder on show and `@name:<file>` for the id a listing gave the item of that name, so a script doesn't depend on
/// how ids are numbered.
public struct AgentScript: Codable, Equatable, Sendable {
    /// A tool call the model makes.
    public struct Call: Codable, Equatable, Sendable {
        public var name: String
        public var args: AgentJSON
        public init(name: String, args: AgentJSON) {
            self.name = name; self.args = args
        }
    }

    /// One model turn: words, tool calls, or both. `stop` may be "refusal" or "max_tokens", for a turn that ends
    /// that way; without it a turn with calls ends for its tools and any other ends the request.
    public struct Turn: Codable, Equatable, Sendable {
        public var text: String?
        public var calls: [Call]?
        public var stop: String?
        public init(text: String? = nil, calls: [Call]? = nil, stop: String? = nil) {
            self.text = text; self.calls = calls; self.stop = stop
        }
    }

    /// What the model does for a message that holds `when`. `failure` is an `AgentFailure` by its raw value: the
    /// request fails with it once the rule's turns are used up, which is at once when there are none.
    public struct Rule: Codable, Equatable, Sendable {
        public var when: String
        public var turns: [Turn]
        public var failure: String?
        public init(when: String, turns: [Turn] = [], failure: String? = nil) {
            self.when = when; self.turns = turns; self.failure = failure
        }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            when = try values.decode(String.self, forKey: .when)
            turns = try values.decodeIfPresent([Turn].self, forKey: .turns) ?? []
            failure = try values.decodeIfPresent(String.self, forKey: .failure)
        }
    }

    public var rules: [Rule]
    /// The answers to an AI search's two questions. Without one, that question fails.
    public var searchPlan: AgentJSON?, searchRank: AgentJSON?
    /// The models the provider lists.
    public var models: [String]

    public init(rules: [Rule], searchPlan: AgentJSON? = nil, searchRank: AgentJSON? = nil, models: [String] = ["scripted-1"]) {
        self.rules = rules; self.searchPlan = searchPlan; self.searchRank = searchRank; self.models = models
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rules = try values.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        searchPlan = try values.decodeIfPresent(AgentJSON.self, forKey: .searchPlan)
        searchRank = try values.decodeIfPresent(AgentJSON.self, forKey: .searchRank)
        models = try values.decodeIfPresent([String].self, forKey: .models) ?? Self.defaultModels
    }

    static let defaultModels = ["scripted-1"]

    /// The script a scripted client starts with: one plain answer to anything, a search plan with no queries of
    /// its own, and a ranking that picks nothing.
    public static let builtIn = AgentScript(
        rules: [Rule(when: "*", turns: [Turn(text: "I can organize, move and copy files in these folders.")])],
        searchPlan: .object(["sort": .string("relevance"), "queries": .array([])]),
        searchRank: .object(["ranked": .array([])]))
}
