#if os(macOS)
import Foundation
import HelmCore

/// A planned query as a Spotlight predicate.
///
/// The predicate is built from expressions, never from text: every word is a constant value on the right of a
/// comparison, so no quote, wildcard, backslash or format sign in it can become part of the predicate's syntax.
/// Words also lose `*`, `?`, `\` and quotes first, so they can't widen a match either. The fields are ANDed; the
/// words of an "any" field, the kinds, the extensions and the dates of `any` are ORed among themselves. Folder words
/// aren't asked of Spotlight, which can't search a path; the matcher checks them on every hit.
enum AISearchPredicates {
    static func predicate(for query: AISearchQuery) -> NSPredicate {
        var parts: [NSPredicate] = []
        parts += query.nameAll.compactMap { word in clean(word).map { like(NSMetadataItemFSNameKey, "*\($0)*") } }
        if let any = or(query.nameAny.compactMap { word in clean(word).map { like(NSMetadataItemFSNameKey, "*\($0)*") } }) {
            parts.append(any)
        }
        // Words inside files are matched as Spotlight and Finder match them: each word as the start of a word.
        parts += query.contentAll.compactMap { word in clean(word).map { like(textContentKey, "\($0)*") } }
        if let kind = kinds(query.kinds) { parts.append(kind) }
        if let ext = or(query.extensions.compactMap { word in clean(word).map { like(NSMetadataItemFSNameKey, "*.\($0)") } }) {
            parts.append(ext)
        }
        if let dates = dates(query) { parts.append(dates) }
        if query.sizeMinBytes > 0 {
            parts.append(compare(NSMetadataItemFSSizeKey, .greaterThanOrEqualTo, NSNumber(value: query.sizeMinBytes), options: []))
        }
        if query.sizeMaxBytes > 0 {
            parts.append(compare(NSMetadataItemFSSizeKey, .lessThanOrEqualTo, NSNumber(value: query.sizeMaxBytes), options: []))
        }
        // A query that asks for nothing Spotlight can check finds nothing here; the walk and the baseline still run.
        guard !parts.isEmpty else { return NSPredicate(value: false) }
        return parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    /// Items of any of `kinds`, read from the type tree Spotlight keeps for each item: a planned query's kinds, and the
    /// kind row's choice under the plain search. Nil for no kind.
    static func kinds(_ kinds: [AISearchKind]) -> NSPredicate? {
        or(kinds.flatMap(\.typeIdentifiers).map { compare(contentTypeTreeKey, .equalTo, $0, options: []) })
    }

    // MARK: Parts

    static let textContentKey = "kMDItemTextContent"
    static let contentTypeTreeKey = "kMDItemContentTypeTree"
    static let dateAddedKey = "kMDItemDateAdded"
    static let lastUsedKey = "kMDItemLastUsedDate"
    static let createdKey = "kMDItemFSCreationDate"

    /// The characters a word loses before it is bound: what Spotlight reads as a wildcard, an escape or a quote.
    static let removed: Set<Character> = ["*", "?", "\\", "\"", "'", "“", "”", "‘", "’", "`"]

    /// `word` without those characters, or nil when nothing is left.
    static func clean(_ word: String) -> String? {
        let kept = String(word.filter { !removed.contains($0) && !$0.isNewline })
        return kept.isEmpty ? nil : kept
    }

    private static func dates(_ query: AISearchQuery) -> NSPredicate? {
        guard query.dateFrom != nil || query.dateTo != nil else { return nil }
        let keys: [String]
        switch query.dateField {
        case .none: return nil
        case .modified: keys = [NSMetadataItemFSContentChangeDateKey]
        case .created: keys = [createdKey]
        case .added: keys = [dateAddedKey]
        case .opened: keys = [lastUsedKey]
        case .any: keys = [NSMetadataItemFSContentChangeDateKey, createdKey, dateAddedKey, lastUsedKey]
        }
        return or(keys.map { key in
            var range: [NSPredicate] = []
            if let from = query.dateFrom { range.append(compare(key, .greaterThanOrEqualTo, from as NSDate, options: [])) }
            if let to = query.dateTo { range.append(compare(key, .lessThanOrEqualTo, to as NSDate, options: [])) }
            return range.count == 1 ? range[0] : NSCompoundPredicate(andPredicateWithSubpredicates: range)
        })
    }

    private static func like(_ key: String, _ pattern: String) -> NSPredicate {
        compare(key, .like, pattern, options: [.caseInsensitive, .diacriticInsensitive])
    }

    private static func compare(_ key: String, _ type: NSComparisonPredicate.Operator, _ value: Any,
                                options: NSComparisonPredicate.Options) -> NSPredicate {
        let left = NSExpression(forKeyPath: key)
        let right = NSExpression(forConstantValue: value)
        return NSComparisonPredicate(leftExpression: left, rightExpression: right, modifier: .direct, type: type, options: options)
    }

    private static func or(_ parts: [NSPredicate]) -> NSPredicate? {
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return NSCompoundPredicate(orPredicateWithSubpredicates: parts)
        }
    }
}
#endif
