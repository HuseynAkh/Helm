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
        let paths = selectedEntries.compactMap { LexicalLocalPath($0.url) }
        guard paths.count == selectedEntries.count else {
            context = .invalidURL; segments = []; return
        }
        var seen: Set<[[UInt8]]> = []
        let entries = zip(selectedEntries, paths).filter { seen.insert($0.1.key).inserted }
        if let (entry, path) = entries.first, entries.count == 1 {
            context = .selectedItem
            segments = Self.ancestry(path.components, leafIsDirectory: entry.isDirectoryLike)
        } else if entries.count > 1 {
            context = .mixedSelection(count: entries.count)
            let parents = entries.map { Array($0.1.components.dropLast()) }
            var common = parents[0]
            for parent in parents.dropFirst() {
                common = Array(zip(common, parent).prefix(while: { $0.0.utf8.elementsEqual($0.1.utf8) }).map { $0.0 })
            }
            segments = Self.ancestry(common, leafIsDirectory: true)
        } else if case .directory(let url) = location {
            guard let path = LexicalLocalPath(url) else { context = .invalidURL; segments = []; return }
            context = .directory
            segments = Self.ancestry(path.components, leafIsDirectory: true)
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
        guard let requested = LexicalLocalPath(segmentID),
              let segment = segments.first(where: { LexicalLocalPath($0.id)?.key == requested.key }),
              let path = LexicalLocalPath(segment.id) else { return nil }
        // Parent spellings remain visible/copyable; shared ItemID still normalizes them.
        guard action == .copyPath || !path.hasParent else { return nil }
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

    private static func ancestry(_ components: [String], leafIsDirectory: Bool) -> [PathPresentationSegment] {
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
        // Preserve invalid standalone inputs verbatim; projection admission refuses them.
        if let path = LexicalLocalPath(url) {
            self.id = URL(fileURLWithPath: path.path, isDirectory: isDirectory)
        } else {
            self.id = url
        }
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
