// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Invalid bounded grammar is reported instead of silently broadening a query (F-044).
public enum SearchParseError: Error, Equatable { case tooLong, tooManyTokens, unterminatedQuote, danglingEscape, invalidFilter(String) }
/// Filename grammar supports quoted phrases and backslash escapes; wildcards stay literal (F-044).
public enum SearchQueryParser {
    public static func tokenize(_ text: String) throws -> [String] {
        guard text.utf8.count <= 4096 else { throw SearchParseError.tooLong }
        var tokens: [String] = []; var token = ""; var quoted = false; var escaped = false
        for character in text {
            if escaped { token.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { quoted.toggle() }
            else if character.isWhitespace && !quoted {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else { token.append(character) }
        }
        guard !escaped else { throw SearchParseError.danglingEscape }
        guard !quoted else { throw SearchParseError.unterminatedQuote }
        if !token.isEmpty { tokens.append(token) }
        guard tokens.count <= 128 else { throw SearchParseError.tooManyTokens }
        return tokens
    }
    public static func compile(_ request: SearchRequest) throws -> SearchSpecification {
        var clauses = request.filters
        for token in try tokenize(request.text) {
            let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { clauses.append(.name(token)); continue }
            let key = parts[0].lowercased(); let value = String(parts[1])
            switch key {
            case "kind":
                let kind = value == "folder" ? FileEntryKind.directory : FileEntryKind(rawValue: value)
                guard let kind else { throw SearchParseError.invalidFilter(token) }; clauses.append(.kind(kind))
            case "ext", "tag":
                guard !value.isEmpty, key != "ext" || !value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty else { throw SearchParseError.invalidFilter(token) }
                clauses.append(key == "ext" ? .ext(value.trimmingCharacters(in: CharacterSet(charactersIn: "."))) : .tag(value))
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
        guard clauses.count <= 256 else { throw SearchParseError.tooManyTokens }
        return SearchSpecification(scope: request.scope, clauses: clauses, includeHidden: request.includeHidden)
    }
    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}
