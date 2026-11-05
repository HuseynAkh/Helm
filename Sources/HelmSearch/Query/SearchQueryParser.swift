// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Invalid bounded grammar is reported instead of silently broadening a query (F-044).
public enum SearchParseError: Error, Equatable {
    case tooLong, tooManyTokens, unterminatedQuote, danglingEscape, invalidFilter(String), nonLocalRoot(URL)
    /// Presentation text; the raw case name never reaches the user.
    public var userMessage: String {
        switch self {
        case .tooLong: return "This search is too long."
        case .tooManyTokens: return "This search has too many terms."
        case .unterminatedQuote: return "This search has an unclosed quotation mark."
        case .danglingEscape: return "This search ends with an unfinished escape."
        case .invalidFilter(let filter): return "\"\(filter)\" is not a valid search filter."
        case .nonLocalRoot: return "Search only covers local folders."
        }
    }
}
/// Filename grammar supports quoted phrases and backslash escapes; wildcards stay literal (F-044).
public enum SearchQueryParser {
    public static func tokenize(_ text: String) throws -> [String] {
        try literalTokens(text).map(\.text)
    }
    private struct Token {
        let text: String
        let isLiteral: Bool
    }
    private static func literalTokens(_ text: String) throws -> [Token] {
        guard text.utf8.count <= 4096 else { throw SearchParseError.tooLong }
        var tokens: [Token] = []; var token = ""; var quoted = false; var escaped = false; var literal = false
        for character in text {
            if escaped { token.append(character); escaped = false }
            else if character == "\\" { escaped = true; literal = true }
            else if character == "\"" { quoted.toggle(); literal = true }
            else if character.isWhitespace && !quoted {
                if !token.isEmpty { tokens.append(Token(text: token, isLiteral: literal)); token = "" }; literal = false
            } else { token.append(character) }
        }
        guard !escaped else { throw SearchParseError.danglingEscape }
        guard !quoted else { throw SearchParseError.unterminatedQuote }
        if !token.isEmpty { tokens.append(Token(text: token, isLiteral: literal)) }
        guard tokens.count <= 128 else { throw SearchParseError.tooManyTokens }
        return tokens
    }
    /// Live typing: `compile` stays strict for saved and programmatic requests, but text that does not parse
    /// yet is the literal filename search legacy Helm always ran, so `"foo` or `kind:` never errors mid-word
    /// and a file named `before:today.txt` stays findable (F-044, OK1-7).
    public static func normalizedForTyping(_ query: SearchQuery) -> SearchQuery {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return query }
        do {
            _ = try compile(SearchRequest(query: query))
            return query
        } catch SearchParseError.unterminatedQuote, SearchParseError.danglingEscape, SearchParseError.invalidFilter {
            var literal = query
            literal.text = ""
            literal.filters = query.filters + [.name(text)]
            // An invalid explicit filter or oversized literal must still surface, so keep the original.
            return (try? compile(SearchRequest(query: literal))) == nil ? query : literal
        } catch { return query }
    }
    public static func compile(_ request: SearchRequest) throws -> SearchSpecification {
        let roots: [URL]
        switch request.scope {
        case .currentFolder(let root): roots = [root]
        case .trash(let values): roots = values
        default: roots = []
        }
        try validateRoots(roots)
        var clauses = request.filters
        for value in try literalTokens(request.text) {
            let token = value.text
            if value.isLiteral { clauses.append(.name(token)); continue }
            let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { clauses.append(.name(token)); continue }
            let key = parts[0].lowercased(); let value = String(parts[1])
            switch key {
            case "kind":
                let kind = value.lowercased() == "folder" ? FileEntryKind.directory : FileEntryKind.allSearchKinds.first { $0.rawValue.lowercased() == value.lowercased() }
                guard let kind else { throw SearchParseError.invalidFilter(token) }; clauses.append(.kind(kind))
            case "ext", "tag":
                guard !value.isEmpty, key != "ext" || !value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty else { throw SearchParseError.invalidFilter(token) }
                clauses.append(key == "ext" ? .ext(value) : .tag(value))
            case "before", "after", "modified":
                guard let date = date(value) else { throw SearchParseError.invalidFilter(token) }
                if key == "before" { clauses.append(.before(date)) }
                else { clauses.append(.after(date)) }
                if key == "modified" { clauses.append(.before(date.addingTimeInterval(86400))) }
            case "size":
                guard let sign = value.first, sign == "<" || sign == ">", let size = Int64(value.dropFirst()), size >= 0 else { throw SearchParseError.invalidFilter(token) }
                clauses.append(sign == "<" ? .sizeLessThan(size) : .sizeGreaterThan(size))
            default: clauses.append(.name(token))
            }
        }
        for index in clauses.indices {
            let clause = clauses[index]
            switch clause {
            case .sizeLessThan(let size), .sizeGreaterThan(let size):
                guard size >= 0 else { throw SearchParseError.invalidFilter("size") }
            case .ext(let value):
                let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard !normalized.isEmpty,
                      value.utf8.count <= 4096 else { throw SearchParseError.invalidFilter("extension") }
                clauses[index] = .ext(normalized)
            case .name(let value), .tag(let value):
                guard !value.isEmpty, value.utf8.count <= 4096 else { throw SearchParseError.invalidFilter("empty or oversized literal") }
            case .before(let date), .after(let date):
                guard date.timeIntervalSince1970.isFinite else { throw SearchParseError.invalidFilter("date") }
            case .kind: break
            }
        }
        guard clauses.count <= 256 else { throw SearchParseError.tooManyTokens }
        return SearchSpecification(scope: request.scope, clauses: clauses, includeHidden: request.includeHidden)
    }
    static func validateRoots(_ roots: [URL]) throws {
        for root in roots where !LocalFileURLAdmission.accepts(root) {
            throw SearchParseError.nonLocalRoot(root)
        }
    }
    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}

private extension FileEntryKind {
    static let allSearchKinds: [FileEntryKind] = [.regular, .directory, .package, .symlinkToDirectory, .symlinkToFile, .danglingSymlink, .alias, .other]
}
