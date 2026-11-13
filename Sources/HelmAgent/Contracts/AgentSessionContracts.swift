import Foundation
import HelmCore

/// A message the person typed. The initializer's first label is `typedByPerson`, and the privacy check lets only
/// the panel's model write it, so nothing but the composer can start a request.
public struct AgentPersonInput: Sendable {
    public let text: String
    /// The tab's selection. It marks items as selected in listings and is never sent as paths.
    public let selectedPaths: [String]
    public init(typedByPerson text: String, selectedPaths: [String]) {
        self.text = text; self.selectedPaths = selectedPaths
    }
}

/// A path that a message may end in. `prefix` and `path` together are the whole message.
public struct AgentTrailingPath: Equatable, Sendable {
    /// From a word that starts with `/`, `~/` or `file://` to the end of the message.
    public let path: String
    /// The message before it.
    public let prefix: String
    public init(path: String, prefix: String) {
        self.path = path; self.prefix = prefix
    }
}

/// What the text in the composer asks for.
public enum AgentComposerIntent: Equatable, Sendable {
    /// Add a folder: "/add" and a path, or a path or a file address typed alone.
    case add(String)
    /// A server address typed alone or after "/add". It is offered to macOS to connect to; nothing is added.
    case connect(ServerLocation)
    case clear
    /// Anything else. A path can hold spaces, so every word that could start one is a candidate, leftmost first:
    /// the longest reading is tried before a shorter one. Empty when the message holds no path.
    case message(String, folderCandidates: [AgentTrailingPath])
    /// A word of the message is shaped like a provider's key. Such a message is never sent.
    case looksLikeKey
    case unknownCommand
    case empty

    /// Reads what the person typed. Only this text is ever read for a command or a path; a model's text and a
    /// file's name never are.
    public static func parse(_ text: String) -> AgentComposerIntent {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .empty }
        let words = message.split(whereSeparator: isSpace)
        if words.contains(where: holdsKey) { return .looksLikeKey }

        if message.hasPrefix("/"), let command = words.first {
            let rest = String(message[command.endIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch command.lowercased() {
            case addCommand:
                return ServerLocation(rest).map(AgentComposerIntent.connect) ?? .add(rest)
            case clearCommand:
                return rest.isEmpty ? .clear : .unknownCommand
            default:
                // A path has a second slash; a command has none. "/Volumes/Photos 2026" is a folder, "/help" isn't.
                return command.dropFirst().contains("/") ? .add(message) : .unknownCommand
            }
        }
        if startsPath(message[...]) || message == "~" { return .add(message) }
        if let server = ServerLocation(message) { return .connect(server) }

        var candidates: [AgentTrailingPath] = []
        // A slash standing alone, as in "this / that", is the top of the disk, which is never a folder to add.
        for word in words where startsPath(word) && word != "/" {
            candidates.append(AgentTrailingPath(path: String(message[word.startIndex...]),
                                                prefix: String(message[..<word.startIndex])))
        }
        return .message(message, folderCandidates: candidates)
    }

    static let addCommand = "/add"
    static let clearCommand = "/clear"
    private static let fileAddressStart = "file://"

    private static func isSpace(_ character: Character) -> Bool { character.isWhitespace || character.isNewline }

    /// Marks that may stand beside a key in a sentence: around it, after it, or between it and a name for it.
    private static let keyNeighbours: Set<Character> = ["=", ":", "\"", "'", "`", "(", ")", "[", "]", "{", "}", "<", ">",
                                                         "“", "”", "‘", "’", "«", "»"]
    private static let keyTrailers = CharacterSet(charactersIn: ".,;:!?…")

    /// Whether a word holds a key: the word itself, or a piece of it between quotes, brackets, `=` or `:`, with a
    /// full stop, comma or the like taken off its end. A file name such as "sk-notes-from-2026-final.txt" holds a
    /// dot inside, so it is never taken for a key.
    private static func holdsKey(_ word: Substring) -> Bool {
        if AgentKeyShape.looksLikeKey(String(word)) { return true }
        return word.split(whereSeparator: keyNeighbours.contains).contains { piece in
            AgentKeyShape.looksLikeKey(String(piece).trimmingCharacters(in: keyTrailers))
        }
    }

    /// Whether a word could be where a path begins: an absolute path, one in the home folder, or a file address.
    private static func startsPath(_ word: Substring) -> Bool {
        word.hasPrefix("/") || word.hasPrefix("~/") || word.lowercased().hasPrefix(fileAddressStart)
    }
}

/// How a plan ended.
public enum AgentPlanOutcome: Equatable, Sendable { case applied(done: Int, skipped: Int), dismissed }

/// What a request is doing right now.
public enum AgentStatus: Equatable, Sendable { case reading(count: Int), thinking, checkingPlan, stopping }

/// What left the app for a request: how many names, and to whom.
public enum AgentTrace: Equatable, Sendable { case sent(names: Int, destination: String) }

/// One of Helm's own lines in a thread.
public enum AgentNotice: Equatable, Sendable {
    case startedOver, stopped, limitReached, foldersNotLoaded(Int), notResponding(label: String), disconnected(label: String)
}

/// What a request sends back while it runs. `.finished` is always last.
public enum AgentSessionEvent: Sendable {
    case status(AgentStatus), trace(AgentTrace), reply(String), plan(AgentChangePlan), notice(AgentNotice),
         failed(AgentFailure), finished
}

/// One window's conversation with a model: its folders, its thread and the plan that waits for the person.
public protocol AgentConversing: AnyObject, Sendable {
    func roots() async -> [AgentScopeRoot]
    /// The folder the tab shows. Nil in Recent, the Trash and search results.
    func setTabFolder(_ input: AgentRootInput?) async -> AgentTabFolder
    func folder(for input: AgentRootInput) async -> AgentFolderRef
    /// Removes an added folder, and starts the thread over.
    func removeRoot(alias: String) async
    /// Sends a message. One request is open at a time.
    func send(_ input: AgentPersonInput) -> AsyncStream<AgentSessionEvent>
    /// Asks to apply the pending plan with these groups ticked. It works once for a plan.
    func beginApply(planID: UUID, ticked: Set<Int>) async -> AgentApplyTicket
    func settle(planID: UUID, _ outcome: AgentPlanOutcome) async
    func stop() async
    /// Drops the thread and every handle. The folders stay.
    func startOver() async
    /// Drops the thread, the added folders and every handle.
    func clear() async
    /// What happens outside a request, such as the thread starting over after the provider changed.
    var notices: AsyncStream<AgentNotice> { get }
}
