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
        let entries = selectedEntries.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
        if let entry = entries.first, entries.count == 1 {
            context = .selectedItem
            segments = Self.ancestry(entry.url, leafIsDirectory: entry.isDirectoryLike)
        } else if entries.count > 1 {
            context = .mixedSelection(count: entries.count)
            let parents = entries.map { $0.url.standardizedFileURL.deletingLastPathComponent().pathComponents }
            var common = parents[0]
            for parent in parents.dropFirst() {
                common = Array(zip(common, parent).prefix(while: { $0.0 == $0.1 }).map { $0.0 })
            }
            let path = common.dropFirst().joined(separator: "/")
            segments = Self.ancestry(URL(fileURLWithPath: "/" + path), leafIsDirectory: true)
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
              let segment = segments.first(where: { $0.id == segmentID.standardizedFileURL }) else { return nil }
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
        url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
            && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil && url.path.hasPrefix("/")
    }

    private static func ancestry(_ url: URL, leafIsDirectory: Bool) -> [PathPresentationSegment] {
        let components = url.standardizedFileURL.pathComponents
        var current = URL(fileURLWithPath: "/")
        var result: [PathPresentationSegment] = []
        for (index, component) in components.enumerated() {
            if index > 0 { current.appendPathComponent(component) }
            result.append(PathPresentationSegment(url: current,
                isDirectory: index < components.count - 1 || leafIsDirectory))
        }
        return result
    }
}

/// Standardized lexical URL identity preserves symlink spelling and F-012 root boundaries.
public struct PathPresentationSegment: Equatable, Sendable, Identifiable {
    public let id: URL
    public let title: String
    public let isDirectory: Bool
    public init(url: URL, isDirectory: Bool) {
        self.id = url.standardizedFileURL
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
