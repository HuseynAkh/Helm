// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmSearch

/// Explicit search feedback avoids silent empty/indexing failures (F-043, B-099).
public enum SearchBarStatus: Equatable, Sendable {
    case idle, gathering, results, noResults, denied(String), cancelled, failed(String)
    public var message: String? {
        switch self {
        case .idle, .results: return nil
        case .gathering: return "Searching…"
        case .noResults: return "No results"
        case .denied(let reason): return "Search access denied: \(reason)"
        case .cancelled: return "Search cancelled"
        case .failed(let reason): return "Search failed: \(reason)"
        }
    }
}

/// Symbolic scope choices keep system Recents separate from Helm Recent (F-043, M23).
public enum SearchScopeChoice: String, CaseIterable, Sendable {
    case thisFolder = "This Folder", home = "Home", thisMac = "This Mac", recents = "Recents"
}

/// Per-tab input projection; host owns debounce, generations and query lifecycle (F-043, B-020/B-023).
public struct SearchBarModel: Equatable, Sendable {
    public var text: String
    public var scope: SearchScopeChoice
    public var kind: FileEntryKind?
    public var folder: URL?
    public var includeHidden: Bool
    public var status: SearchBarStatus
    public var truncated: Bool
    public init(text: String = "", scope: SearchScopeChoice = .home, kind: FileEntryKind? = nil,
                folder: URL? = nil, includeHidden: Bool = false, status: SearchBarStatus = .idle,
                truncated: Bool = false) {
        self.text = text; self.scope = scope; self.kind = kind; self.folder = folder
        self.includeHidden = includeHidden; self.status = status; self.truncated = truncated
    }
    /// Nil means empty input or unavailable folder; never silently widens scope.
    public var request: SearchRequest? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let domain: HelmCore.SearchScope
        switch scope {
        case .thisFolder:
            guard let folder, folder.isFileURL else { return nil }
            domain = .currentFolder(folder)
        case .home: domain = .home
        case .thisMac: domain = .thisMac
        case .recents: domain = .recents
        }
        return SearchRequest(text: query, scope: domain, filters: kind.map { [.kind($0)] } ?? [], includeHidden: includeHidden)
    }
    public var scopeUnavailable: Bool { scope == .thisFolder && !(folder?.isFileURL ?? false) }
}

/// Location column projection distinguishes same-named subtree results (F-043, M-24).
public struct SearchLocationColumnModel: Equatable, Sendable {
    public let resultURL: URL
    public init(resultURL: URL) { self.resultURL = resultURL }
    public var enclosingURL: URL { resultURL.deletingLastPathComponent() }
    public var text: String { enclosingURL.path }
    public var accessibilityLabel: String { "Location: \(text)" }
}
