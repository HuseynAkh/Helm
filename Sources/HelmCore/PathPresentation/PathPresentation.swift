// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Selected-result ancestry supplements the F-012 bar without changing its editing behavior.
public struct PathPresentation: Equatable, Sendable {
    public enum Context: Equatable, Sendable {
        case directory, selectedItem, mixedSelection(count: Int), virtual(Location), invalidURL
    }
    public let context: Context
    public let segments: [PathPresentationSegment]

    public init(location: Location, selectedEntries: [FileEntry]) {
        guard selectedEntries.allSatisfy({ Self.isLocal($0.url) }) else {
            context = .invalidURL; segments = []; return
        }
        var seen: Set<String> = []
        let entries = selectedEntries.filter { seen.insert(LexicalLocalPath.key($0.url)).inserted }
        if let entry = entries.first, entries.count == 1 {
            context = .selectedItem
            segments = Self.ancestry(entry.url, leafIsDirectory: entry.isDirectoryLike)
        } else if entries.count > 1 {
            context = .mixedSelection(count: entries.count)
            let parents = entries.map { Array(LexicalLocalPath.components($0.url).dropLast()) }
            var common = parents[0]
            for parent in parents.dropFirst() {
                common = Array(zip(common, parent).prefix(while: { $0.0 == $0.1 }).map { $0.0 })
            }
            let path = common.dropFirst().joined(separator: "/")
            segments = Self.ancestry(URL(fileURLWithPath: "/" + path, isDirectory: true), leafIsDirectory: true)
        } else if case .directory(let url) = location {
            guard Self.isLocal(url) else { context = .invalidURL; segments = []; return }
            context = .directory
            segments = Self.ancestry(url, leafIsDirectory: true)
        } else {
            context = .virtual(location)
            segments = []
        }
    }

    public static func build(location: Location, selectedEntries: [FileEntry]) -> PathPresentation {
        PathPresentation(location: location, selectedEntries: selectedEntries)
    }

    /// Only segments in this projection can produce intents. The host revalidates before acting.
    public func intent(_ action: PathSegmentAction, segmentID: URL) -> PathSegmentIntent? {
        guard Self.isLocal(segmentID),
              let segment = segments.first(where: { LexicalLocalPath.key($0.id) == LexicalLocalPath.key(segmentID) }) else { return nil }
        // Parent spellings remain visible/copyable; shared ItemID still normalizes them.
        guard action == .copyPath || !LexicalLocalPath.hasParent(segment.id) else { return nil }
        switch action {
        case .navigate: return segment.isDirectory ? .navigate(segment.id) : nil
        case .openTab: return segment.isDirectory ? .openTab(segment.id) : nil
        case .dropTarget: return segment.isDirectory ? .dropTarget(segment.id) : nil
        case .copyPath: return .copyPath(segment.id.path)
        case .reveal:
            guard segment.id.path != "/" else { return nil }
            return .reveal(directory: segment.id.deletingLastPathComponent(), selected: ItemID(url: segment.id))
        }
    }

    private static func isLocal(_ url: URL) -> Bool {
        LexicalLocalPath.isLocal(url)
    }

    private static func ancestry(_ url: URL, leafIsDirectory: Bool) -> [PathPresentationSegment] {
        let components = LexicalLocalPath.components(url)
        var result: [PathPresentationSegment] = []
        for index in components.indices {
            let path = "/" + components.prefix(index + 1).dropFirst().joined(separator: "/")
            let directory = index < components.count - 1 || leafIsDirectory
            result.append(PathPresentationSegment(url: URL(fileURLWithPath: path, isDirectory: directory),
                                                  isDirectory: directory))
        }
        return result
    }
}

/// Lexical URL identity (parent components remain literal) preserves symlink spelling and F-012 root boundaries.
public struct PathPresentationSegment: Equatable, Sendable, Identifiable {
    public let id: URL
    public let title: String
    public let isDirectory: Bool
    public init(url: URL, isDirectory: Bool) {
        self.id = URL(fileURLWithPath: LexicalLocalPath.key(url), isDirectory: isDirectory)
        self.title = id.path == "/" ? "/" : id.lastPathComponent
        self.isDirectory = isDirectory
    }
}

/// Explicit segment gestures for the result path bar, separate from F-014 text entry.
public enum PathSegmentAction: CaseIterable, Sendable { case navigate, reveal, openTab, copyPath, dropTarget }
/// Reveal retains the containing folder and selected identity (F-050); no filesystem work occurs.
public enum PathSegmentIntent: Equatable, Sendable {
    case navigate(URL), reveal(directory: URL, selected: ItemID), openTab(URL), copyPath(String), dropTarget(URL)
}
