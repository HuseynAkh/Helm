import Foundation
import HelmCore

/// The three questions an AI search asks a model, as JSON schemas, and how their answers become Helm's own values.
///
/// Every schema takes only typed fields: every property is required, no object takes a property it doesn't list,
/// and "nothing" is an empty array, an empty string or 0. Answers are read tolerantly, since a model may wrap its
/// JSON in words or leave a field out, and whatever doesn't fit is dropped rather than guessed at. Limits are kept
/// by the session after reading, never trusted to the schema.
public enum AISearchSchemas {
    /// The name of the first question, which plans the searches to run.
    public static let planName = "search_plan"
    /// The name of the second question, which orders the rows found.
    public static let rankName = "search_rank"
    /// The name of the look question, which says which of the files shown match.
    public static let lookName = "search_look"

    /// The most queries read from one answer. The session keeps fewer.
    static let queriesRead = 12
    /// The most ranked rows read from one answer.
    static let rowsRead = 200
    /// The most items read from one look's answer, and the longest phrase of what was seen that is read at all.
    static let looksRead = 200
    static let seenRead = 2_000

    public static let plan: AgentJSON = record(required: ["sort", "queries"], [
        "sort": choice(AISearchSort.allNames),
        "queries": list(of: query, "1 to 6, strictest first; each later one relaxes one thing.")
    ])

    public static let rank: AgentJSON = record(required: ["ranked"], [
        "ranked": list(of: record(required: ["row", "why"], [
            "row": .object(["type": .string("integer")]),
            "why": list(of: choice(SearchReasonCode.allCases.map(\.rawValue)))
        ]), "Up to 20 rows from the list, best first.")
    ])

    public static let look: AgentJSON = record(required: ["items"], [
        "items": list(of: record(required: ["item", "fits", "seen"], [
            "item": .object(["type": .string("integer")]),
            "fits": .object(["type": .string("boolean")]),
            "seen": text("What the item shows or says that matters to the request, in at most 80 characters.")
        ]), "One entry for each item judged, by its number.")
    ])

    private static let query: AgentJSON = record(required: [
        "name_all", "name_any", "content_all", "folder_any", "kinds", "extensions", "date_field", "date_from",
        "date_to", "size_min_bytes", "size_max_bytes"
    ], [
        "name_all": words(),
        "name_any": words(),
        "content_all": words("Single words from the request that must appear inside the file."),
        "folder_any": words(),
        "kinds": list(of: choice(AISearchKind.allCases.map(\.rawValue))),
        "extensions": words(),
        "date_field": choice(AISearchDateField.allNames),
        "date_from": text("YYYY-MM-DD or empty."),
        "date_to": text("YYYY-MM-DD or empty."),
        "size_min_bytes": .object(["type": .string("integer")]),
        "size_max_bytes": .object(["type": .string("integer")])
    ])

    // MARK: Answers

    /// The plan in an answer, before clamping. Days are read in `calendar`'s time zone: a range starts at the start
    /// of its first day and ends at the end of its last. Throws `AgentFailure.unreadable` when there is no plan.
    public static func plan(from answer: Data, calendar: Calendar) throws -> AISearchPlan {
        guard case .object(let members) = try json(in: answer) else { throw AgentFailure.unreadable }
        let sort = members["sort"].flatMap(\.text).flatMap(AISearchSort.init(rawValue:)) ?? .relevance
        guard case .array(let items)? = members["queries"] else { throw AgentFailure.unreadable }
        let queries = items.prefix(queriesRead).compactMap { item -> AISearchQuery? in
            guard case .object(let fields) = item else { return nil }
            return query(fields, calendar: calendar)
        }
        return AISearchPlan(sort: sort, queries: queries)
    }

    /// The rows an answer ranked, best first, each with the codes the model gave it. A row that isn't a whole number
    /// is dropped, and so is a code Helm doesn't know. Throws `AgentFailure.unreadable` when there is no ranking.
    public static func verdicts(from answer: Data) throws -> [AISearchVerdict] {
        guard case .object(let members) = try json(in: answer), case .array(let items)? = members["ranked"] else {
            throw AgentFailure.unreadable
        }
        return items.prefix(rowsRead).compactMap { item -> AISearchVerdict? in
            guard case .object(let fields) = item, let row = fields["row"].flatMap(\.whole), row > 0, row <= Int64(Int32.max)
            else { return nil }
            var codes: [SearchReasonCode] = []
            for code in strings(fields["why"]).compactMap(SearchReasonCode.init(rawValue:)) where !codes.contains(code) {
                codes.append(code)
            }
            return AISearchVerdict(row: Int(row), why: codes)
        }
    }

    /// What a look's answer says of each item, in its order, before the session checks it: a number that isn't a
    /// whole number, or a `fits` that isn't true or false, drops the entry, and a missing phrase is empty. Throws
    /// `AgentFailure.unreadable` when there is no list of items.
    public static func looks(from answer: Data) throws -> [AISearchLook] {
        guard case .object(let members) = try json(in: answer), case .array(let items)? = members["items"] else {
            throw AgentFailure.unreadable
        }
        return items.prefix(looksRead).compactMap { item -> AISearchLook? in
            guard case .object(let fields) = item, let number = fields["item"].flatMap(\.whole), number > 0,
                  number <= Int64(Int32.max), case .bool(let fits)? = fields["fits"] else { return nil }
            let seen = fields["seen"].flatMap(\.text).map { String($0.prefix(seenRead)) } ?? ""
            return AISearchLook(item: Int(number), fits: fits, seen: seen)
        }
    }

    // MARK: Reading

    private static func query(_ fields: [String: AgentJSON], calendar: Calendar) -> AISearchQuery {
        var kinds: [AISearchKind] = []
        for kind in strings(fields["kinds"]).compactMap(AISearchKind.init(rawValue:)) where !kinds.contains(kind) {
            kinds.append(kind)
        }
        let field = fields["date_field"].flatMap(\.text).flatMap(AISearchDateField.init(rawValue:)) ?? .none
        return AISearchQuery(
            nameAll: strings(fields["name_all"]), nameAny: strings(fields["name_any"]),
            contentAll: strings(fields["content_all"]), folderAny: strings(fields["folder_any"]),
            kinds: kinds, extensions: strings(fields["extensions"]), dateField: field,
            dateFrom: day(fields["date_from"], calendar: calendar, end: false),
            dateTo: day(fields["date_to"], calendar: calendar, end: true),
            sizeMinBytes: bytes(fields["size_min_bytes"]), sizeMaxBytes: bytes(fields["size_max_bytes"]))
    }

    /// The strings of an array, at most a few dozen, each no longer than a field could keep. Anything else is dropped.
    private static func strings(_ value: AgentJSON?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.prefix(32).compactMap { item in
            guard let text = item.text, text.count <= 64 else { return nil }
            return text
        }
    }

    private static func bytes(_ value: AgentJSON?) -> Int64 {
        guard case .number(let number)? = value, number.isFinite, number > 0 else { return 0 }
        return number >= 9e18 ? Int64.max : Int64(number)
    }

    /// A day written YYYY-MM-DD: its first instant, or with `end` its last. Nil for anything else.
    private static func day(_ value: AgentJSON?, calendar: Calendar, end: Bool) -> Date? {
        guard let text = value?.text, text.count == 10 else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
              (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(dayOfMonth) else { return nil }
        let wanted = DateComponents(year: year, month: month, day: dayOfMonth)
        guard let start = calendar.date(from: wanted),
              calendar.component(.day, from: start) == dayOfMonth, calendar.component(.month, from: start) == month
        else { return nil }
        guard end else { return start }
        return calendar.date(byAdding: .day, value: 1, to: start).map { $0.addingTimeInterval(-0.001) }
    }

    /// The answer's JSON. A model that put words round its JSON is read from its first object.
    static func json(in answer: Data) throws -> AgentJSON {
        if let whole = try? AgentJSON(data: answer) { return whole }
        guard let object = firstObject(in: answer), let found = try? AgentJSON(data: object) else {
            throw AgentFailure.unreadable
        }
        return found
    }

    /// The bytes of the first balanced `{…}` in `data`, minding strings and their escapes.
    private static func firstObject(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let start = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var depth = 0, inString = false, escaping = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaping { escaping = false } else if byte == UInt8(ascii: "\\") { escaping = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return Data(bytes[start...index]) }
            default: break
            }
        }
        return nil
    }

    // MARK: Schema parts

    private static func text(_ description: String) -> AgentJSON {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func words(_ description: String? = nil) -> AgentJSON {
        list(of: .object(["type": .string("string")]), description)
    }

    private static func choice(_ names: [String]) -> AgentJSON {
        .object(["type": .string("string"), "enum": .array(names.map(AgentJSON.string))])
    }

    private static func list(of items: AgentJSON, _ description: String? = nil) -> AgentJSON {
        var members: [String: AgentJSON] = ["type": .string("array"), "items": items]
        if let description { members["description"] = .string(description) }
        return .object(members)
    }

    /// An object that takes exactly the properties listed, all of them required.
    private static func record(required: [String], _ properties: [String: AgentJSON]) -> AgentJSON {
        .object(["type": .string("object"), "additionalProperties": .bool(false),
                 "required": .array(required.map(AgentJSON.string)), "properties": .object(properties)])
    }
}

private extension AgentJSON {
    var text: String? { if case .string(let value) = self { return value }; return nil }
    /// A number with no fraction.
    var whole: Int64? {
        guard case .number(let value) = self, value.isFinite, value.rounded() == value, abs(value) < 9e15 else { return nil }
        return Int64(value)
    }
}

private extension AISearchSort {
    static let allNames = ["relevance", "newest", "oldest", "largest", "smallest"]
}

private extension AISearchDateField {
    static let allNames = ["none", "any", "modified", "created", "added", "opened"]
}
