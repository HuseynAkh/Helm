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
///  "searchLooks": [{"when": "kite", "fits": [{"name": "DSC_0193.png", "seen": "A red kite over the sand"}],
///                   "misses": ["IMG_0042.png"]}],
///  "models": ["scripted-1"]}
/// ```
///
/// The first rule whose `when` is in the person's message answers it, without regard to case; `*` is in every
/// message. Each of a rule's turns is one model turn of the request. In a call's arguments `@root` stands for the
/// folder on show, `@home` for the home folder while Whole Mac is on, and `@name:<file>` for the id a listing gave the
/// item of that name, so a script doesn't depend on how ids are numbered.
///
/// AI search's look question is answered by the first of `searchLooks` whose `when` is in the request: the items
/// shown under a name it lists in `fits` fit, with what was seen, the ones it lists in `misses` don't, and the rest
/// go unjudged. With no such rule the question fails, as a search question with no answer does.
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

    /// How AI search's look question is answered for a request that holds `when`; `*` is in every request.
    public struct LookRule: Codable, Equatable, Sendable {
        /// An item, by its file name, that fits, and what the model says it saw.
        public struct Fit: Codable, Equatable, Sendable {
            public var name: String, seen: String
            public init(name: String, seen: String) { self.name = name; self.seen = seen }
        }
        public var when: String
        public var fits: [Fit]
        /// Items, by file name, that don't fit.
        public var misses: [String]
        /// An `AgentFailure` by its raw value that the question fails with while it carries pictures, as a provider
        /// that takes no pictures answers. Asked again without them, it is answered.
        public var picturesFailure: String?
        public init(when: String, fits: [Fit] = [], misses: [String] = [], picturesFailure: String? = nil) {
            self.when = when; self.fits = fits; self.misses = misses; self.picturesFailure = picturesFailure
        }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            when = try values.decode(String.self, forKey: .when)
            fits = try values.decodeIfPresent([Fit].self, forKey: .fits) ?? []
            misses = try values.decodeIfPresent([String].self, forKey: .misses) ?? []
            picturesFailure = try values.decodeIfPresent(String.self, forKey: .picturesFailure)
        }
    }

    public var rules: [Rule]
    /// The answers to an AI search's plan and ranking. Without one, that question fails.
    public var searchPlan: AgentJSON?, searchRank: AgentJSON?
    /// The answers to AI search's look question.
    public var searchLooks: [LookRule]
    /// The models the provider lists.
    public var models: [String]

    public init(rules: [Rule], searchPlan: AgentJSON? = nil, searchRank: AgentJSON? = nil, searchLooks: [LookRule] = [],
                models: [String] = ["scripted-1"]) {
        self.rules = rules; self.searchPlan = searchPlan; self.searchRank = searchRank; self.searchLooks = searchLooks
        self.models = models
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rules = try values.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        searchPlan = try values.decodeIfPresent(AgentJSON.self, forKey: .searchPlan)
        searchRank = try values.decodeIfPresent(AgentJSON.self, forKey: .searchRank)
        searchLooks = try values.decodeIfPresent([LookRule].self, forKey: .searchLooks) ?? []
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
