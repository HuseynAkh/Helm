// DRAFT: pending Opus review.
import Foundation
import HelmCore
import HelmFileSystem

/// Discover visible top-level Home folders once before ranking (F-045, B-026).
/// This nonisolated async helper uses the filesystem's IO executor; ranking performs no IO.
public enum PreferredRoots {
    public static func standard(home: URL) -> [URL] {
        ["Documents", "Desktop", "Downloads", "Projects", "Work", "Pictures", "Movies", "Music",
         "Developer", "Sites", "Code", "Coding", "Applications", "Public"].map { home.appendingPathComponent($0) }
    }
    /// Hosts await this once per search and inject the result into SearchRankingContext.
    /// Read errors propagate so the host can disclose failure and choose the standard roots.
    public static func discover(home: URL, fileSystem: any FileSystem) async throws -> [URL] {
        try Task.checkCancellation()
        try SearchQueryParser.validateRoots([home])
        var roots = standard(home: home)
        var seen = Set(roots.map { $0.standardizedFileURL.path })
        var discovered: [URL] = []
        for try await batch in fileSystem.enumerate(home, options: EnumerationOptions(includeHidden: false, resolveSymlinkTargets: false)) {
            try Task.checkCancellation()
            for entry in batch where entry.kind == .directory && !entry.isHidden && !entry.name.hasPrefix(".") {
                let url = entry.url.standardizedFileURL
                guard entry.name.lowercased() != "library",
                      url.deletingLastPathComponent().path == home.standardizedFileURL.path,
                      seen.insert(url.path).inserted else { continue }
                discovered.append(entry.url)
            }
        }
        try Task.checkCancellation()
        roots.append(contentsOf: discovered.sorted { $0.path < $1.path })
        return roots
    }
}
