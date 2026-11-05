// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmFileSystem

/// No-follow source snapshot for F-052 preflight; links are leaves (B-039).
public struct SourceEntry: Sendable, Hashable {
    public let source: URL
    public let relativePath: String
    public let kind: FileEntryKind
    public let size: Int64
    public let changeToken: ChangeToken
    public init(source: URL, relativePath: String, kind: FileEntryKind, size: Int64, changeToken: ChangeToken) {
        self.source = source; self.relativePath = relativePath; self.kind = kind; self.size = size; self.changeToken = changeToken
    }
}
/// Explicit immutable inputs keep F-052 planning independent of disk and UI state (B-031).
public struct PlanningContext: Sendable {
    public let sourceManifest: [SourceEntry]
    /// Destination metadata captured with names, preserving replacement evidence (F-052/B-042).
    public let existingEntries: [URL: FileEntry]
    public let availableBytes: [URL: Int64]
    public let caseSensitive: [URL: Bool]
    public let existingNames: [URL: Set<String>]
    public let volumeIDs: [URL: String]
    public let defaultPolicy: ConflictPolicy
    public init(sourceManifest: [SourceEntry] = [], availableBytes: [URL: Int64] = [:], caseSensitive: [URL: Bool] = [:],
                existingNames: [URL: Set<String>] = [:], volumeIDs: [URL: String] = [:], defaultPolicy: ConflictPolicy = ConflictPolicy(), existingEntries: [URL: FileEntry] = [:]) {
        self.existingEntries = existingEntries
        self.sourceManifest = sourceManifest; self.availableBytes = availableBytes; self.caseSensitive = caseSensitive
        self.existingNames = existingNames; self.volumeIDs = volumeIDs; self.defaultPolicy = defaultPolicy
    }
    func names(at url: URL) -> Set<String>? { existingNames.first { $0.key.standardizedFileURL.path == url.standardizedFileURL.path }?.value }
    func sensitive(at url: URL) -> Bool { caseSensitive.first { $0.key.standardizedFileURL.path == url.standardizedFileURL.path }?.value ?? false }
}
/// Async snapshot collection feeds the pure planner (F-052); never follows manifest symlinks.
public struct PlanningContextBuilder: Sendable {
    private let fileSystem: any FileSystem
    public init(fileSystem: any FileSystem) { self.fileSystem = fileSystem }
    public func build(sources: [URL], destinations: [URL], caseSensitive: [URL: Bool] = [:],
                      policy: ConflictPolicy = ConflictPolicy()) async throws -> PlanningContext {
        var sensitivity = caseSensitive
        var manifest: [SourceEntry] = []
        var names: [URL: Set<String>] = [:]
        var existingEntries: [URL: FileEntry] = [:]
        var volumes: [URL: String] = [:]
        var capacity: [URL: Int64] = [:]
        for source in sources {
            volumes[source] = try await fileSystem.volumeIdentifier(for: source)
            var pending: [(URL, String)] = [(source, "")]
            while let (url, relative) = pending.popLast() {
                try Task.checkCancellation()
                let entry = try await fileSystem.entry(at: url)
                manifest.append(SourceEntry(source: url, relativePath: relative, kind: entry.kind, size: entry.size, changeToken: entry.changeToken))
                if entry.kind == .directory || entry.kind == .package {
                    for try await batch in fileSystem.enumerate(url, options: EnumerationOptions(includeHidden: true, resolveSymlinkTargets: false)) {
                        pending.append(contentsOf: batch.map { ($0.url, relative.isEmpty ? $0.name : relative + "/" + $0.name) })
                    }
                }
            }
        }
        for directory in Set(destinations + sources.map { $0.deletingLastPathComponent() }) {
            if !sensitivity.keys.contains(where: { $0.standardizedFileURL.path == directory.standardizedFileURL.path }) {
                sensitivity[directory] = (try? await fileSystem.isCaseSensitive(at: directory)) ?? false
            }
            var children: Set<String> = []
            for try await batch in fileSystem.enumerate(directory, options: EnumerationOptions(includeHidden: true, resolveSymlinkTargets: false)) {
                for entry in batch {
                    children.insert(entry.name)
                    // Match entry(at:) link classification without traversing target children.
                    existingEntries[entry.url] = entry.kind == .danglingSymlink
                        ? try await fileSystem.entry(at: entry.url) : entry
                }
            }
            names[directory] = children
            volumes[directory] = try await fileSystem.volumeIdentifier(for: directory)
            capacity[directory] = try await fileSystem.availableCapacity(of: directory)
        }
        return PlanningContext(sourceManifest: manifest, availableBytes: capacity, caseSensitive: sensitivity,
                               existingNames: names, volumeIDs: volumes, defaultPolicy: policy, existingEntries: existingEntries)
    }
}
