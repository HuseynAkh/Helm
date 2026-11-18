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

/// One file a model is shown in a look question, numbered from 1 within the question.
public struct AISearchLookItem: Sendable {
    public let item: Int
    /// The name, escaped; the folder in Helm's words; the kind's word: as a row has them.
    public let name: String, folder: String, kind: String
    public let modified: Date?
    /// What Helm read inside the file on this Mac, with the person's permit: its first lines and pages, what a picture
    /// or a video shows and the text found in it, and the small pictures made of it. All of it is data from the file.
    public let summary: AgentContentSummary
    public init(item: Int, name: String, folder: String, kind: String, modified: Date?, summary: AgentContentSummary) {
        self.item = item; self.name = name; self.folder = folder; self.kind = kind; self.modified = modified
        self.summary = summary
    }
}

/// What a model said of one item it looked at: whether it fits the request, and what it saw that matters.
public struct AISearchLook: Hashable, Sendable {
    public let item: Int
    public let fits: Bool
    /// Plain text of 80 characters at most once the session has read it; it may be empty.
    public let seen: String
    public init(item: Int, fits: Bool, seen: String) { self.item = item; self.fits = fits; self.seen = seen }
}

/// The questions of an AI search: what to look for, which of the files shown match when Read contents is on, and
/// which of the rows found fit best.
///
/// No question offers a tool, and each answer is read into typed values and cut down to Helm's limits before
/// anything uses it. A question that gets no answer in time fails as timed out.
///
/// What is sent: the request and the folder searched in Helm's words for the plan; rows of names, folders, kinds,
/// rounded sizes and dates for the ranking; and for the look, while the person's Read contents switch is on, each
/// file's row facts with what Helm read inside it on this Mac (a document's first lines and pages, what a picture or a
/// video shows and the text in it) and, unless the caller leaves them out, the small pictures Helm made of it. Never a
/// path: the home folder's path in a file's text is written as `~`.
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
    /// How long one question may take, in seconds. A model that reasons first can take most of a minute.
    public static func callSeconds(isLocal: Bool) -> Double { isLocal ? 120 : 60 }
    /// How long one look question may take, in seconds: it carries pictures.
    public static func lookSeconds(isLocal: Bool) -> Double { isLocal ? 180 : 120 }
    /// The most pictures one look question carries. Past it an item's later video frames are left out first.
    static let picturesPerLook = AgentContentLimits.picturesPerRequest
    /// The longest phrase of what was seen that is kept.
    public static let seenCharacters = 80

    /// What to look for. Every query is clamped to the request (`AISearchQuery.clamped`), a query left with nothing
    /// to look for is dropped, and at most six are kept. When none is left, the plan is one name search for the
    /// request's own words, so a model that answers nothing useful still leaves a search to run.
    ///
    /// `kind` is the one the person chose in the kind row. The model is told it, and every query it answers is then
    /// kept to it (`AISearchPlan.limited(to:)`), so no answer can widen the search to another kind. It is applied
    /// after the empty queries are dropped, so a query that asked for nothing never becomes "every photo".
    ///
    /// `readsContents` is the search's Read contents switch: the model is told Helm can also look inside photos and
    /// videos, so it may put what they show in the content words. Those words are still clamped to the request.
    public func plan(request: String, scopeLabel: String, today: Date, languageCode: String,
                     kind: AISearchKind? = nil, readsContents: Bool = false) async throws -> AISearchPlan {
        let request = Self.trimmed(request)
        let ask = AgentStructuredAsk(
            system: readsContents ? AISearchPrompt.planSystemReadingContents : AISearchPrompt.planSystem,
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

    /// Which of `items` match the request, as the model judged them, in its order: at most `looksPerQuestion` items
    /// are shown. `kind` is the one the person chose in the kind row. With `pictures`, the pictures in the items'
    /// summaries follow the question's words, each after its label ("Item 3", a video's frames "Item 3, frame 2"),
    /// `picturesPerLook` at most; without, the question is words alone and the on-device words stand in. Each file's
    /// text has the home folder's path in `homes` written as `~`, and the items, all text Helm built from files, then
    /// pass Helm's check on what it sends (`AgentOutboundCheck`) for each of `homes`: items that still hold the path in
    /// any spelling aren't sent, and the question fails as unreadable. The person's own request isn't checked, as a
    /// path typed in the panel isn't. An item that wasn't shown, or that was already answered, is dropped, and each
    /// phrase of what was seen is cleaned (`cleaned(_:)`).
    public func look(request: String, kind: AISearchKind?, items: [AISearchLookItem], homes: [String],
                     pictures: Bool) async throws -> [AISearchLook] {
        let request = Self.trimmed(request)
        // A file whose words still hold the home folder's path is left out of the question, not the rest with it.
        let shown = items.prefix(AgentContentLimits.looksPerQuestion).filter { item in
            let words = AISearchPrompt.lookItems([item], pictured: [:], homes: homes, calendar: calendar)
            return homes.allSatisfy { AgentOutboundCheck.helmTextIsClean(words, home: $0) }
        }
        guard !shown.isEmpty else { throw AgentFailure.unreadable }
        let attached = pictures ? Self.pictures(of: shown, limit: client.isLocal ? AgentContentLimits.localPicturesPerLook : Self.picturesPerLook) : []
        var counts: [Int: Int] = [:]
        for picture in attached { counts[picture.item, default: 0] += 1 }
        let itemsText = AISearchPrompt.lookItems(shown, pictured: counts, homes: homes, calendar: calendar)
        guard homes.allSatisfy({ AgentOutboundCheck.helmTextIsClean(itemsText, home: $0) }) else { throw AgentFailure.unreadable }
        let ask = AgentStructuredAsk(
            system: AISearchPrompt.lookSystem,
            user: AISearchPrompt.lookUser(request: request, kind: kind, items: itemsText),
            schemaName: AISearchSchemas.lookName, schema: AISearchSchemas.look, pictures: attached.map(\.picture))
        let reply = try await answer(to: ask, seconds: Self.lookSeconds(isLocal: client.isLocal))
        let numbers = Set(shown.map(\.item))
        var answered: Set<Int> = []
        var kept: [AISearchLook] = []
        for look in try AISearchSchemas.looks(from: reply) where numbers.contains(look.item) && answered.insert(look.item).inserted {
            kept.append(AISearchLook(item: look.item, fits: look.fits, seen: Self.cleaned(look.seen)))
        }
        return kept
    }

    /// A phrase a model wrote, as plain text: each run of spaces and line breaks one space, every control, format,
    /// private-use or unassigned character left out, and `seenCharacters` at most, trimmed.
    static func cleaned(_ phrase: String) -> String {
        var kept = String.UnicodeScalarView()
        var spaced = true
        for scalar in phrase.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !spaced { kept.append(" "); spaced = true }
                continue
            }
            guard AgentTextEscaper.isClean(String(scalar)) else { continue }
            kept.append(scalar)
            spaced = false
        }
        let cut = String(String(kept).prefix(seenCharacters))
        return cut.trimmingCharacters(in: .whitespaces)
    }

    /// The pictures of `items` a look question carries, in item order, each with its label: an item's first picture
    /// before any item's second, so a long video can't crowd out the pictures after it.
    private static func pictures(of items: [AISearchLookItem], limit: Int) -> [(item: Int, picture: AgentAskPicture)] {
        var chosen: [Int: Int] = [:]
        var left = limit
        var depth = 0
        while left > 0 {
            var added = false
            for item in items where left > 0 && item.summary.images.count > depth {
                chosen[item.item, default: 0] += 1
                left -= 1
                added = true
            }
            guard added else { break }
            depth += 1
        }
        var found: [(item: Int, picture: AgentAskPicture)] = []
        for item in items {
            var frame = 0
            for image in item.summary.images.prefix(chosen[item.item] ?? 0) {
                var label = "Item \(item.item)"
                if case .frame = image.source {
                    frame += 1
                    label += ", frame \(frame)"
                }
                found.append((item.item, AgentAskPicture(label: label, image: image)))
            }
        }
        return found
    }

    // MARK: Parts

    /// Asks one question, within the time a question may take. Cancelling the caller cancels the question.
    private func answer(to ask: AgentStructuredAsk, seconds: Double? = nil) async throws -> Data {
        try await Self.answer(from: client, to: ask, seconds: seconds ?? Self.callSeconds(isLocal: client.isLocal))
    }

    /// The question's time starts once the client has what a request needs: reading a key or a sign-in from the
    /// keychain can wait on macOS asking the person, and that wait is theirs, not the provider's.
    static func answer(from client: any AgentModelClient, to ask: AgentStructuredAsk, seconds: Double) async throws -> Data {
        do {
            try await client.prepare()
            try Task.checkCancellation()
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
