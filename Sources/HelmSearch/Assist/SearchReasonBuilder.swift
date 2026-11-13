import Foundation
import HelmCore

/// The words that say why a result matched, and how a request was read, built only from facts Helm holds.
///
/// A model answers with reason codes and never with words, so nothing here repeats a phrase it wrote. Every word of
/// a query is a single token by the time it gets here (`AISearchQuery.clamped`), a word looked for inside files is
/// one the person typed, and every word and name passes `AgentTextEscaper`, so a line can't hold hidden characters.
/// A code Helm can't back with a fact is dropped, and no line names a path.
public enum SearchReasonBuilder {
    /// The most facts one reason line holds.
    public static let factsPerLine = 2

    /// The reason line for one result: the first two codes Helm can back, in the order given, or nil when it can
    /// back none. `query` is the planned query that found the item, if one did.
    public static func reason(codes: [SearchReasonCode], entry: FileEntry, query: AISearchQuery?, scopeRoot: URL?,
                              calendar: Calendar, locale: Locale) -> SearchReason? {
        var used: [SearchReasonCode] = []
        var facts: [String] = []
        for code in codes where !used.contains(code) {
            guard facts.count < factsPerLine,
                  let fact = fact(code, entry: entry, query: query, scopeRoot: scopeRoot, calendar: calendar, locale: locale)
            else { continue }
            used.append(code); facts.append(fact)
        }
        guard !facts.isEmpty else { return nil }
        return SearchReason(codes: used, line: facts.joined(separator: separator))
    }

    /// How a query was read: "12 matches · PDF · “invoice” · Mar–Jun 2026". With a count it is the status bar's
    /// line; without one it is a line of the list of queries that ran.
    public static func readAs(count: Int?, query: AISearchQuery, calendar: Calendar, locale: Locale) -> String {
        var parts: [String] = []
        if let count { parts.append(matches(count, locale: locale)) }
        if !query.kinds.isEmpty { parts.append(query.kinds.map(kindWord).joined(separator: ", ")) }
        if !query.extensions.isEmpty { parts.append(query.extensions.map { "." + escaped($0) }.joined(separator: ", ")) }
        let names = query.nameAll + query.nameAny
        if !names.isEmpty { parts.append(names.map(quoted).joined(separator: ", ")) }
        if !query.contentAll.isEmpty { parts.append(mentions + query.contentAll.map(quoted).joined(separator: ", ")) }
        if !query.folderAny.isEmpty { parts.append(inFolder + query.folderAny.map(escaped).joined(separator: ", ")) }
        if let range = dateRange(query, calendar: calendar, locale: locale) {
            let word = dateWord(query.dateField)
            parts.append(word.map { $0 + " " + range } ?? range)
        }
        if let sizes = sizeRange(query) { parts.append(sizes) }
        return parts.joined(separator: separator)
    }

    // MARK: Words
    // HelmSearch can't see the strings of AI mode, so the words of these lines live here.

    static let separator = " · "
    static let mentions = "Mentions "
    static let nameHas = "Name has "
    static let inFolder = "In "

    /// The word for each kind, as a reason line shows it.
    static func kindWord(_ kind: AISearchKind) -> String {
        switch kind {
        case .pdf: return "PDF"
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .folder: return "Folder"
        case .document: return "Document"
        case .text: return "Text"
        case .code: return "Code"
        case .spreadsheet: return "Spreadsheet"
        case .presentation: return "Presentation"
        case .archive: return "Archive"
        case .app: return "App"
        case .font: return "Font"
        }
    }

    /// The word before a date, for the field it is.
    static func dateWord(_ field: AISearchDateField) -> String? {
        switch field {
        case .modified: return "Modified"
        case .created: return "Created"
        case .opened: return "Opened"
        case .added: return "Added"
        case .none, .any: return nil
        }
    }

    // MARK: Facts

    private static func fact(_ code: SearchReasonCode, entry: FileEntry, query: AISearchQuery?, scopeRoot: URL?,
                             calendar: Calendar, locale: Locale) -> String? {
        switch code {
        case .name:
            guard let query, let word = (query.nameAll + query.nameAny).first(where: { AISearchMatcher.holds(entry.name, $0) })
            else { return nil }
            return nameHas + quoted(word)
        case .content:
            // Only a query with words from inside files found the item through them, and those words are the person's.
            guard let word = query?.contentAll.first else { return nil }
            return mentions + quoted(word)
        case .kind:
            return AISearchMatcher.kind(of: entry).map(kindWord)
        case .date:
            guard let shown = shownDate(entry, query: query), let word = dateWord(shown.field) else { return nil }
            return word + " " + day(shown.date, calendar: calendar, locale: locale, withYear: !isThisYear(shown.date, calendar))
        case .folder:
            guard let query, !query.folderAny.isEmpty else { return nil }
            let folders = AISearchMatcher.folderNames(of: entry.url, below: scopeRoot)
            guard let folder = folders.last(where: { name in query.folderAny.contains { AISearchMatcher.holds(name, $0) } })
            else { return nil }
            return inFolder + escaped(folder)
        case .size:
            guard !entry.isDirectoryLike, entry.kind != .package else { return nil }
            return size(entry.size)
        }
    }

    /// The date a reason names: the one the query asked about, or for any date the first Helm can read that falls in
    /// its range, or else when the item was modified.
    private static func shownDate(_ entry: FileEntry, query: AISearchQuery?) -> (field: AISearchDateField, date: Date)? {
        let field = query?.dateField ?? .none
        switch field {
        case .modified, .created, .opened, .added:
            return AISearchMatcher.date(field, of: entry).map { (field, $0) }
        case .any:
            if let query {
                for candidate in AISearchMatcher.readableFields {
                    if let date = AISearchMatcher.date(candidate, of: entry), AISearchMatcher.inRange(date, query) {
                        return (candidate, date)
                    }
                }
            }
            return AISearchMatcher.date(.modified, of: entry).map { (.modified, $0) }
        case .none:
            return AISearchMatcher.date(.modified, of: entry).map { (.modified, $0) }
        }
    }

    // MARK: Formatting

    private static func quoted(_ word: String) -> String { "“" + escaped(word) + "”" }
    private static func escaped(_ word: String) -> String { AgentTextEscaper.escape(word) }

    private static func matches(_ count: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.numberStyle = .decimal; formatter.usesGroupingSeparator = true
        let number = formatter.string(from: NSNumber(value: count)) ?? String(count)
        return number + (count == 1 ? " match" : " matches")
    }

    /// A size as Helm's size column writes it: "2.4 GB".
    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func sizeRange(_ query: AISearchQuery) -> String? {
        switch (query.sizeMinBytes > 0, query.sizeMaxBytes > 0) {
        case (true, true): return size(query.sizeMinBytes) + "–" + size(query.sizeMaxBytes)
        case (true, false): return "≥ " + size(query.sizeMinBytes)
        case (false, true): return "≤ " + size(query.sizeMaxBytes)
        case (false, false): return nil
        }
    }

    private static func isThisYear(_ date: Date, _ calendar: Calendar) -> Bool {
        calendar.component(.year, from: date) == calendar.component(.year, from: Date())
    }

    /// "14 Mar", or "14 Mar 2025".
    private static func day(_ date: Date, calendar: Calendar, locale: Locale, withYear: Bool) -> String {
        formatted(date, withYear ? "d MMM yyyy" : "d MMM", calendar: calendar, locale: locale)
    }

    private static func formatted(_ date: Date, _ format: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = locale
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// A query's dates in few words. Whole months read "Mar–Jun 2026"; other days read "14 Mar–2 Apr", with the
    /// year when it isn't this one. A range open at one end has a dash on that side.
    private static func dateRange(_ query: AISearchQuery, calendar: Calendar, locale: Locale) -> String? {
        guard query.dateField != .none else { return nil }
        switch (query.dateFrom, query.dateTo) {
        case (nil, nil): return nil
        case (let from?, nil): return day(from, calendar: calendar, locale: locale, withYear: true) + "–"
        case (nil, let to?): return "–" + day(to, calendar: calendar, locale: locale, withYear: true)
        case (let from?, let to?):
            let sameYear = calendar.component(.year, from: from) == calendar.component(.year, from: to)
            if isFirstDayOfMonth(from, calendar), isLastDayOfMonth(to, calendar) {
                let sameMonth = sameYear && calendar.component(.month, from: from) == calendar.component(.month, from: to)
                if sameMonth { return formatted(to, "MMM yyyy", calendar: calendar, locale: locale) }
                let start = formatted(from, sameYear ? "MMM" : "MMM yyyy", calendar: calendar, locale: locale)
                return start + "–" + formatted(to, "MMM yyyy", calendar: calendar, locale: locale)
            }
            let withYear = !(sameYear && isThisYear(to, calendar))
            if calendar.isDate(from, inSameDayAs: to) { return day(to, calendar: calendar, locale: locale, withYear: withYear) }
            let start = day(from, calendar: calendar, locale: locale, withYear: withYear && !sameYear)
            return start + "–" + day(to, calendar: calendar, locale: locale, withYear: withYear)
        }
    }

    private static func isFirstDayOfMonth(_ date: Date, _ calendar: Calendar) -> Bool {
        calendar.component(.day, from: date) == 1
    }

    private static func isLastDayOfMonth(_ date: Date, _ calendar: Calendar) -> Bool {
        guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { return false }
        return calendar.component(.month, from: next) != calendar.component(.month, from: date)
    }
}
