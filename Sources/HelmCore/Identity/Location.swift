import Foundation

/// Virtual locations cannot silently target Home for mutations (F-030, B-031).
public enum Location: Hashable, Sendable, Codable {
    case directory(URL), recent, trash
    // Normalize navigation spelling only; ItemID identity policy is independent.
    var canonicalNavigationLocation: Location {
        guard case .directory(let url) = self else { return self }
        return .directory(URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true))
    }
    public var mutationTarget: URL? {
        if case .directory(let url) = self { return url }
        return nil
    }
    public var kind: LocationKind {
        switch self { case .directory: return .directory; case .recent: return .recent; case .trash: return .trash }
    }
}
/// Search remains an overlay, preserving per-tab navigation (F-043).
public enum LocationKind: String, Hashable, Sendable, Codable { case directory, recent, trash }
