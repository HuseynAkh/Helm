import Foundation
import HelmCore

/// Whether one item answers one planned query, from what Helm knows of it: its name, kind, folders, dates and size.
///
/// Every hit of a search a model planned is checked here again, whoever found it, so an index that answers loosely
/// or a stand-in that answers anything can't put an item in the results that the query doesn't describe.
/// Words are compared without case, accents or width, as the plain search compares them.
public enum AISearchMatcher {
    /// The kind of an item, from the one kind table.
    public static func kind(of entry: FileEntry) -> AISearchKind? {
        AISearchKind.of(typeIdentifier: entry.contentTypeIdentifier, extension: entry.url.pathExtension, kind: entry.kind)
    }

    /// Whether `entry` is of `kind`, or of a kind `kind` covers, as the kind row's filter asks. An item the table has
    /// no word for, such as a link, is of none.
    public static func isOf(_ kind: AISearchKind, _ entry: FileEntry) -> Bool {
        guard let found = self.kind(of: entry) else { return false }
        return kind.covers(found)
    }

    /// Whether `entry` answers `query`.
    ///
    /// `scopeRoot` is the folder searched, when there is one: the item must be inside it, and the folder words are
    /// looked for in the folders between it and the item. `contentVerified` says the index already checked this item
    /// against what Helm can't check itself: the words inside the file, and the dates it was added and last opened.
    /// Without it, a query that asks for any of those doesn't match, so a walk that can't see inside files never
    /// claims it did.
    public static func matches(_ entry: FileEntry, _ query: AISearchQuery, scopeRoot: URL?, contentVerified: Bool) -> Bool {
        if let scopeRoot, !isInside(entry.url, scopeRoot) { return false }
        let name = entry.name
        if !query.nameAll.allSatisfy({ holds(name, $0) }) { return false }
        if !query.nameAny.isEmpty, !query.nameAny.contains(where: { holds(name, $0) }) { return false }
        if !query.contentAll.isEmpty, !contentVerified { return false }
        if !query.folderAny.isEmpty {
            let folders = folderNames(of: entry.url, below: scopeRoot)
            guard query.folderAny.contains(where: { word in folders.contains { holds($0, word) } }) else { return false }
        }
        if !query.kinds.isEmpty {
            guard let kind = kind(of: entry), query.kinds.contains(where: { $0.covers(kind) }) else { return false }
        }
        if !query.extensions.isEmpty {
            let ext = entry.url.pathExtension.lowercased()
            guard !ext.isEmpty, query.extensions.contains(where: { $0.lowercased() == ext }) else { return false }
        }
        if !datesMatch(entry, query, contentVerified: contentVerified) { return false }
        if query.sizeMinBytes > 0 || query.sizeMaxBytes > 0 {
            guard !entry.isDirectoryLike, entry.kind != .package else { return false }
            if query.sizeMinBytes > 0, entry.size < query.sizeMinBytes { return false }
            if query.sizeMaxBytes > 0, entry.size > query.sizeMaxBytes { return false }
        }
        return true
    }

    // MARK: Inside pictures and videos

    /// What a picture or a video answers of `words`, the words a query looks for inside files, from what Read
    /// contents read in it on this Mac. Every word must be in the text it holds or be one of the things it shows;
    /// otherwise, and for anything but a picture or a video that was read, nil.
    public static func sighting(of words: [String], in summary: AgentContentSummary) -> AISearchSighting? {
        guard !words.isEmpty, summary.status == .read else { return nil }
        let medium: AISearchSighting.Medium
        switch summary.kind {
        case .image: medium = .image
        case .video: medium = .video
        case .text, .pdf, .other: return nil
        }
        let text = summary.foundText.joined(separator: " ")
        let labels = summary.labels.filter { $0.confidence >= AgentContentLimits.labelConfidence }
                .prefix(AgentContentLimits.labels(for: summary.kind))
        var textWords: [String] = [], shown: [String] = []
        for word in words {
            // A label that is the word itself first, so "sky" is shown as sky rather than as blue sky.
            if let label = labels.first(where: { names($0, word, wholly: true) }) ?? labels.first(where: { names($0, word) }) {
                if !shown.contains(label.words) { shown.append(label.words) }
            } else if holds(text, word) {
                textWords.append(word)
            } else {
                return nil
            }
        }
        return AISearchSighting(medium: medium, textWords: textWords, labels: shown)
    }

    /// Whether a label names what `word` does: one of its words is the word, or the word with a plural ending, so
    /// "dogs" finds "dog" and "sky" finds "blue_sky". `wholly` asks for the whole label to be the word.
    static func names(_ label: AgentContentLabel, _ word: String, wholly: Bool = false) -> Bool {
        let wanted = word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: matchingLocale)
        let forms: Set<String> = [wanted, wanted.hasSuffix("es") ? String(wanted.dropLast(2)) : wanted,
                                  wanted.hasSuffix("s") ? String(wanted.dropLast()) : wanted]
        let parts = label.identifier.lowercased().split(whereSeparator: { $0 == "_" || $0 == " " }).map(String.init)
        if wholly { return parts.count == 1 && forms.contains(parts[0]) }
        return parts.contains { forms.contains($0) }
    }

    // MARK: Parts

    /// Whether `text` holds `word`, without case, accents or width.
    static func holds(_ text: String, _ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        return text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                          locale: matchingLocale) != nil
    }

    /// The names of the folders between `root` and the item, nearest the root first. With no root, every folder
    /// above the item.
    static func folderNames(of url: URL, below root: URL?) -> [String] {
        let parts = components(url.deletingLastPathComponent())
        guard let root else { return Array(parts.dropFirst()) }
        let rootParts = components(root)
        guard parts.starts(with: rootParts) else { return [] }
        return Array(parts.dropFirst(rootParts.count))
    }

    /// The date of `entry` that a date field reads, when Helm knows it. Nobody tells Helm when an item was added.
    static func date(_ field: AISearchDateField, of entry: FileEntry) -> Date? {
        switch field {
        case .modified: return entry.modificationDate == .distantPast ? nil : entry.modificationDate
        case .created: return entry.creationDate == .distantPast ? nil : entry.creationDate
        case .opened: return entry.lastOpenedDate
        case .added, .none, .any: return nil
        }
    }

    /// The dates Helm can read for `.any`, in the order a reason names them.
    static let readableFields: [AISearchDateField] = [.modified, .created, .opened]

    /// Whether `date` falls in the query's range. Both ends are included.
    static func inRange(_ date: Date, _ query: AISearchQuery) -> Bool {
        if let from = query.dateFrom, date < from { return false }
        if let to = query.dateTo, date > to { return false }
        return true
    }

    private static func datesMatch(_ entry: FileEntry, _ query: AISearchQuery, contentVerified: Bool) -> Bool {
        guard query.dateField != .none, query.dateFrom != nil || query.dateTo != nil else { return true }
        switch query.dateField {
        case .none: return true
        case .any:
            if readableFields.contains(where: { date($0, of: entry).map { inRange($0, query) } == true }) { return true }
            // The index checked the dates Helm can't read.
            return contentVerified
        case .added: return contentVerified
        case .opened:
            guard let opened = entry.lastOpenedDate else { return contentVerified }
            return inRange(opened, query)
        case .modified, .created:
            guard let value = date(query.dateField, of: entry) else { return false }
            return inRange(value, query)
        }
    }

    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        let parts = components(url), rootParts = components(root)
        return parts.count > rootParts.count && parts.starts(with: rootParts)
    }

    private static func components(_ url: URL) -> [String] { url.standardizedFileURL.pathComponents }

    private static let matchingLocale = Locale(identifier: "en_US_POSIX")
}
