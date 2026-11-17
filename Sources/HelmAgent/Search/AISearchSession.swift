import Foundation
import HelmCore

/// One row of a search's results as a model is shown it, numbered from 1.
public struct AISearchRow: Hashable, Sendable {
    public let row: Int
    /// The name, escaped; the folder in Helm's words (`AgentItemFilter.placeWords`, joined by " / "); the kind's word.
    public let name: String, folder: String, kind: String
    /// The size rounded to two figures.
    public let bytes: Int64, modified: Date?, created: Date?
    /// The file is in a cloud and not on this Mac.
    public let cloud: Bool
    public init(row: Int, name: String, folder: String, kind: String, bytes: Int64, modified: Date?, created: Date?, cloud: Bool) {
        self.row = row; self.name = name; self.folder = folder; self.kind = kind
        self.bytes = bytes; self.modified = modified; self.created = created; self.cloud = cloud
    }
}

/// One row a model chose, with the codes of the facts that made it fit.
public struct AISearchVerdict: Hashable, Sendable {
    public let row: Int
    public let why: [SearchReasonCode]
    public init(row: Int, why: [SearchReasonCode]) { self.row = row; self.why = why }
}

/// The two questions of an AI search: what to look for, and which of the rows found fit best.
///
/// Neither question offers a tool, and each answer is read into typed values and cut down to Helm's limits before
/// anything uses it. A question that gets no answer in time fails as timed out.
public struct AISearchSession: Sendable {
    private let client: any AgentModelClient
    private let calendar: Calendar

    public init(client: any AgentModelClient) { self.init(client: client, calendar: .current) }
    init(client: any AgentModelClient, calendar: Calendar) { self.client = client; self.calendar = calendar }

    /// The most characters of a request that are sent.
    public static let requestCharacters = 500
    /// The most queries a plan keeps.
    static let maxQueries = 6
    /// The most rows a model may order; the rest follow in the order Helm found them.
    static let maxRanked = 20

    /// The most rows sent to be ranked. A model on this Mac often has a small context, so it gets half.
    public static func maxRows(isLocal: Bool) -> Int { isLocal ? 30 : 60 }
    /// How long one question may take, in seconds.
    public static func callSeconds(isLocal: Bool) -> Double { isLocal ? 60 : 20 }

    /// What to look for. Every query is clamped to the request (`AISearchQuery.clamped`), a query left with nothing
    /// to look for is dropped, and at most six are kept. When none is left, the plan is one name search for the
    /// request's own words, so a model that answers nothing useful still leaves a search to run.
    ///
    /// `kind` is the one the person chose in the kind row. The model is told it, and every query it answers is then
    /// kept to it (`AISearchPlan.limited(to:)`), so no answer can widen the search to another kind. It is applied
    /// after the empty queries are dropped, so a query that asked for nothing never becomes "every photo".
    public func plan(request: String, scopeLabel: String, today: Date, languageCode: String,
                     kind: AISearchKind? = nil) async throws -> AISearchPlan {
        let request = Self.trimmed(request)
        let ask = AgentStructuredAsk(
            system: AISearchPrompt.planSystem,
            user: AISearchPrompt.planUser(request: request, scopeLabel: scopeLabel, today: today, languageCode: languageCode,
                                          kind: kind, calendar: calendar),
            schemaName: AISearchSchemas.planName, schema: AISearchSchemas.plan)
        let reply = try await answer(to: ask)
        let raw = try AISearchSchemas.plan(from: reply, calendar: calendar)
        var queries: [AISearchQuery] = []
        for query in raw.queries.map({ $0.clamped(request: request) }) where !Self.isEmpty(query) && !queries.contains(query) {
            queries.append(query)
            if queries.count == Self.maxQueries { break }
        }
        if queries.isEmpty { queries = [Self.ownWords(of: request)].filter { !Self.isEmpty($0) } }
        let plan = AISearchPlan(sort: raw.sort, queries: queries)
        return kind.map { plan.limited(to: $0) } ?? plan
    }

    /// The rows that fit best, best first. A row that wasn't sent, or was already named, is dropped, and at most
    /// twenty are kept.
    public func rank(request: String, rows: [AISearchRow]) async throws -> [AISearchVerdict] {
        let request = Self.trimmed(request)
        let ask = AgentStructuredAsk(
            system: AISearchPrompt.rankSystem,
            user: AISearchPrompt.rankUser(request: request, rows: rows, calendar: calendar),
            schemaName: AISearchSchemas.rankName, schema: AISearchSchemas.rank)
        let reply = try await answer(to: ask)
        let sent = Set(rows.map(\.row))
        var named: Set<Int> = []
        var kept: [AISearchVerdict] = []
        for verdict in try AISearchSchemas.verdicts(from: reply) where sent.contains(verdict.row) && named.insert(verdict.row).inserted {
            kept.append(verdict)
            if kept.count == Self.maxRanked { break }
        }
        return kept
    }

    // MARK: Parts

    /// Asks one question, within the time a question may take. Cancelling the caller cancels the question.
    private func answer(to ask: AgentStructuredAsk) async throws -> Data {
        let client = self.client
        let seconds = Self.callSeconds(isLocal: client.isLocal)
        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await client.structured(ask) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw AgentFailure.timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw AgentFailure.unreadable }
                return first
            }
        } catch let failure as AgentFailure {
            throw failure
        } catch {
            if Task.isCancelled || error is CancellationError { throw AgentFailure.cancelled }
            throw AgentFailure.unreadable
        }
    }

    private static func trimmed(_ request: String) -> String {
        String(request.trimmingCharacters(in: .whitespacesAndNewlines).prefix(requestCharacters))
    }

    /// Whether a query looks for nothing at all, which would match everything.
    static func isEmpty(_ query: AISearchQuery) -> Bool {
        query.nameAll.isEmpty && query.nameAny.isEmpty && query.contentAll.isEmpty && query.folderAny.isEmpty
            && query.kinds.isEmpty && query.extensions.isEmpty && query.dateField == .none
            && query.sizeMinBytes == 0 && query.sizeMaxBytes == 0
    }

    /// One name search for the request's own words: a name that holds any of them.
    static func ownWords(of request: String) -> AISearchQuery {
        let words = request.split(whereSeparator: { $0.isWhitespace || ",;:!?\"'“”‘’()[]{}".contains($0) })
            .map(String.init).filter { $0.count >= 2 }
        return AISearchQuery(nameAny: words).clamped(request: request)
    }
}
