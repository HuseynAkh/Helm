import Foundation

/// How the top-level items are grouped on screen. Recent puts its folders apart from everything else, under two
/// light headings; every other place is one plain run. It's presentation only: the items keep the snapshot's
/// order, so selection, keys, Quick Look, drags and commands work exactly as they do without headings.
public struct ContentSections: Equatable, Sendable {
    public enum Kind: String, Sendable { case all, folders, files }

    public struct Section: Equatable, Sendable {
        public let kind: Kind
        /// Positions among the snapshot's top-level items.
        public let range: Range<Int>
        public init(kind: Kind, range: Range<Int>) { self.kind = kind; self.range = range }
        /// The heading's words, or nil for the plain run, which has none.
        public var title: String? {
            switch kind {
            case .all: return nil
            case .folders: return "Folders"
            case .files: return "Files"
            }
        }
    }

    public let sections: [Section]
    /// Headings show only when there's more than one group.
    public var hasHeadings: Bool { sections.count > 1 }

    /// One plain run of every top-level item.
    public init(rootCount: Int) { sections = [Section(kind: .all, range: 0..<max(0, rootCount))] }
    private init(sections: [Section]) { self.sections = sections }

    /// Folders and files get their own headings only in Recent, with Folders on top, no search running, and
    /// at least one of each. Anywhere else, or when one group would be empty, it's today's single run.
    public static func make(for tab: TabState) -> ContentSections {
        make(for: tab.snapshot, searching: tab.search != nil)
    }
    public static func make(for snapshot: PresentationSnapshot, searching: Bool) -> ContentSections {
        let plain = ContentSections(rootCount: snapshot.rootCount)
        guard snapshot.location == .recent, !searching, snapshot.rankByID == nil, snapshot.sort.directoriesFirst else { return plain }
        let roots = snapshot.sortedEntries.prefix(snapshot.rootCount)
        // Folders and links to folders count as folders; apps, other packages, aliases and links to files don't.
        let folders = roots.prefix { $0.isDirectoryLike }.count
        guard folders > 0, folders < snapshot.rootCount, !roots.dropFirst(folders).contains(where: \.isDirectoryLike) else { return plain }
        return ContentSections(sections: [Section(kind: .folders, range: 0..<folders),
                                          Section(kind: .files, range: folders..<snapshot.rootCount)])
    }

    /// Where a top-level item sits: which group, and how far into it.
    public func position(ofRoot index: Int) -> (section: Int, item: Int)? {
        for (number, section) in sections.enumerated() where section.range.contains(index) {
            return (number, index - section.range.lowerBound)
        }
        return nil
    }
    /// The top-level item at a place in a group.
    public func rootIndex(section: Int, item: Int) -> Int? {
        guard sections.indices.contains(section), item >= 0 else { return nil }
        let range = sections[section].range
        return item < range.count ? range.lowerBound + item : nil
    }
}
