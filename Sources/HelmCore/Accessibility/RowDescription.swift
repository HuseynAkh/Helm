// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Full names and selected state supplement F-035/F-036 cells, fixing missing speech (B-061).
public struct RowDescription: Sendable {
    /// Brief retains identity/state; standard adds size/tags/cloud; detailed adds modified date.
    public enum Verbosity: Sendable { case brief, standard, detailed }
    public let verbosity: Verbosity
    public let relativeDates: Bool
    public init(verbosity: Verbosity = .standard, relativeDates: Bool = true) {
        self.verbosity = verbosity
        self.relativeDates = relativeDates
    }

    public func label(for entry: FileEntry, selected: Bool, tags: TagSet = TagSet(),
                      formatting: AccessibilityFormatting) -> String {
        var parts: [String] = [entry.name, kindDescription(entry)]
        if selected { parts.append("selected") }
        if verbosity != .brief {
            // Directory metadata size is not the aggregate size of its contents.
            if !entry.isDirectoryLike, entry.kind != .package, let size = formatting.bytes(entry.size) { parts.append(size) }
            var seen: Set<String> = []
            let names: [String] = tags.tags.map(\.name).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted
            }
            if !names.isEmpty { parts.append("Tags: " + names.joined(separator: ", ")) }
            switch entry.cloudAvailability {
            case .local: parts.append("available offline")
            case .evicted: parts.append("in cloud, not downloaded")
            case .downloading: parts.append("downloading")
            case .unknown: break
            }
        }
        if verbosity == .detailed,
           let date = formatting.modifiedDate(entry.modificationDate, relative: relativeDates) {
            parts.append("modified " + date)
        }
        return parts.joined(separator: ", ")
    }

    private func kindDescription(_ entry: FileEntry) -> String {
        if let kind = entry.localizedKindDescription,
           !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return kind }
        switch entry.kind {
        case .regular: return "file"
        case .directory: return "folder"
        case .package: return "package"
        case .symlinkToDirectory: return "symbolic link to folder"
        case .symlinkToFile: return "symbolic link to file"
        case .danglingSymlink: return "broken symbolic link"
        case .alias: return "alias"
        case .other: return "item"
        }
    }
}
