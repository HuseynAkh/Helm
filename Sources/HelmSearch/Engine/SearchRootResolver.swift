// DRAFT: pending Opus review.
import Foundation
import HelmCore

/// Explicit roots preserve symbolic scope intent without widening searches (F-043, B-099).
public protocol SearchScopeResolving: Sendable {
    func roots(for scope: SearchScope) async throws -> [URL]
}
/// Composition-root supplied bookmarks and browsable removable volumes preserve F-044 scope.
/// Recents requires metadata (F-043). The host supplies volume eligibility; no discovery occurs here.
public struct SearchRootResolver: SearchScopeResolving {
    public let home: URL
    public let computerRoots: [URL]
    public let bookmarkRoots: [URL]
    public let removableVolumeRoots: [URL]
    public init(home: URL, computerRoots: [URL] = [], bookmarkRoots: [URL] = [], removableVolumeRoots: [URL] = []) {
        self.home = home; self.computerRoots = computerRoots
        self.bookmarkRoots = bookmarkRoots; self.removableVolumeRoots = removableVolumeRoots
    }
    public func roots(for scope: SearchScope) async throws -> [URL] {
        switch scope {
        case .currentFolder(let root): return [root]
        case .home, .userFolders:
            var seen = Set<String>()
            return ([home] + bookmarkRoots + removableVolumeRoots).filter {
                seen.insert($0.standardizedFileURL.path).inserted
            }
        case .thisMac, .computer: return computerRoots
        case .trash(let roots): return roots
        case .recents: throw EnumerationSearchError.recentsRequireMetadataSource
        }
    }
}
