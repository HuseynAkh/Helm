import Foundation
import HelmCore

/// New File includes both file and directory templates; natural ordering is deterministic (F-057).
public struct TemplateProvider: Sendable {
    private let fileSystem: any FileSystem
    private let home: URL
    public init(fileSystem: any FileSystem, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileSystem = fileSystem; self.home = home
    }
    public func templates() async throws -> [FileEntry] {
        var entries: [FileEntry] = []
        do {
            for try await batch in fileSystem.enumerate(home.appendingPathComponent("Templates"), options: EnumerationOptions()) {
                entries.append(contentsOf: batch)
            }
        } catch { if FileSystemError.mapping(error) != .notFound { throw error } }
        return ItemSort(directoriesFirst: false).sorted(entries)
    }
}
