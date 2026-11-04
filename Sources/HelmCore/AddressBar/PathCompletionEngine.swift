import Foundation

/// F-016–F-023 filtering and completion. Slash requests always enumerate anew (B-050/B-052).
public struct PathCompletionEngine: Sendable {
    private let listing: any DirectoryListing
    public init(listing: any DirectoryListing) { self.listing = listing }

    public func complete(_ request: CompletionRequest) async throws -> [CompletionRow] {
        try Task.checkCancellation()
        let children: [CompletionCandidate] = try await listing.children(of: request.parent, includeHidden: request.showHidden)
        try Task.checkCancellation()
        return Self.rows(for: request, children: children)
    }

    public static func request(for text: String, currentDirectory: URL, home: URL,
                               showHidden: Bool, generation: Generation) -> CompletionRequest? {
        guard !text.isEmpty, !text.contains("\0") else { return nil }
        let entry: PathEntry = PathEntry(text: text, currentDirectory: currentDirectory, home: home)
        return CompletionRequest(parent: entry.directory, prefix: entry.prefix,
                                 isSlashBrowsing: entry.isSlashBrowsing, showHidden: showHidden, generation: generation)
    }

    public static func rows(for request: CompletionRequest, children: [CompletionCandidate], limit: Int = 50) -> [CompletionRow] {
        guard limit > 0 else { return [] }
        var rows: [CompletionRow] = children.filter { child in
            (request.showHidden || (!child.isHidden && !child.name.hasPrefix("."))) &&
            (request.prefix.isEmpty || child.name.range(of: request.prefix, options: [.anchored, .caseInsensitive]) != nil)
        }.map { child in
            CompletionRow(name: child.name, path: child.url.path,
                          isDirectory: child.isDirectory || child.symlinkTargetIsDirectory)
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison: ComparisonResult = lhs.name.localizedStandardCompare(rhs.name)
            return comparison == .orderedSame ? lhs.path < rhs.path : comparison == .orderedAscending
        }
        let parent: URL = request.parent.standardizedFileURL
        if request.isSlashBrowsing && parent.path != "/" {
            rows.insert(CompletionRow(name: "..", path: parent.deletingLastPathComponent().path,
                                      isDirectory: true, isParentLink: true), at: 0)
        }
        // Review Fix 60 takes precedence: the parent row counts toward the cap.
        return Array(rows.prefix(limit))
    }

    public static func ghostSuffix(typed: String, selected: CompletionRow?, caretAtEnd: Bool) -> String? {
        guard caretAtEnd, !typed.isEmpty, let selected, !selected.isParentLink,
              let range = selected.completionText.range(of: typed, options: [.anchored, .caseInsensitive]) else { return nil }
        let suffix: String = String(selected.completionText[range.upperBound...])
        return suffix.isEmpty ? nil : suffix
    }

    public static func ghostSuffix(typed: String, selected: CompletionRow?, caretAtEnd: Bool,
                                   currentDirectory: URL, home: URL) -> String? {
        guard !typed.isEmpty else { return nil }
        let entry: PathEntry = PathEntry(text: typed, currentDirectory: currentDirectory, home: home)
        let expanded: String = entry.isSlashBrowsing ? PathEntry.directoryText(entry.resolvedURL) : entry.resolvedURL.path
        return ghostSuffix(typed: expanded, selected: selected, caretAtEnd: caretAtEnd)
    }

    /// F-023 review fix: retain a typed home shorthand and canonicalize the accepted casing.
    public static func acceptedText(row: CompletionRow, typed: String, home: URL) -> String {
        let homePath: String = home.standardizedFileURL.path
        if typed == "~" || typed.hasPrefix("~/") {
            if row.path == homePath { return row.isDirectory ? "~/" : "~" }
            let prefix: String = PathEntry.directoryText(home)
            if row.completionText.hasPrefix(prefix) { return "~/" + String(row.completionText.dropFirst(prefix.count)) }
        }
        return row.completionText
    }
}
