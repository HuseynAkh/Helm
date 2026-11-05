// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

internal struct LocationOptionsDocument: Codable, Sendable {
    var defaults: ViewOptions
    var records: [LocationOptionsRecord]
}
internal struct LocationOptionsRecord: Codable, Sendable {
    let key: String
    let options: ViewOptions
}

/// Persistent per-location options preserve F-036/F-040/F-065 and symbolic identity (B-031).
/// One shared instance per document; reads update LRU, and callers explicitly flush.
@MainActor public final class LocationViewOptionsStore {
    public let capacity: Int
    public let recoveryBackupURL: URL?
    public var isReadOnly: Bool { recoveryBackupURL != nil }
    public var defaults: ViewOptions { document.defaults }
    public var count: Int { document.records.count }
    public var keysLeastRecentlyUsedFirst: [String] { document.records.map(\.key) }
    private var document: LocationOptionsDocument
    private let file: PreferenceDocumentFile<LocationOptionsDocument>
    private var revision: UInt64 = 0
    // Internal admission seam for deterministic revision-order verification.
    internal var beforeSave: (@Sendable (UInt64) async -> Void)?

    public init(url: URL, capacity: Int = 256, defaults: ViewOptions = ViewOptions()) async throws {
        self.capacity = max(0, capacity)
        let file = PreferenceDocumentFile<LocationOptionsDocument>(url: url)
        self.file = file
        let loaded = try await file.load(defaults: LocationOptionsDocument(defaults: defaults, records: [])) { data in
            let version = try JSONDecoder().decode(PreferenceDocumentHeader.self, from: data).schemaVersion
            guard version == 1 else { throw PersistenceError.unsupportedVersion(version) }
            return try JSONDecoder().decode(VersionedDocument<LocationOptionsDocument>.self, from: data).items
        }
        document = loaded.0; recoveryBackupURL = loaded.1
        // Last occurrence wins for duplicate records; persisted order is least-recent first.
        var seen: Set<String> = []
        document.records = Array(document.records.reversed().filter { seen.insert($0.key).inserted }
            .prefix(self.capacity).reversed())
    }
    public static func stableKey(for location: Location) -> String {
        switch location {
        case .directory(let url): return "path:" + url.standardizedFileURL.path
        case .recent: return "symbol:recent"
        case .trash: return "symbol:trash"
        }
    }
    public func options(for location: Location) -> ViewOptions {
        let key = Self.stableKey(for: location)
        guard let index = document.records.firstIndex(where: { $0.key == key }) else { return defaults }
        let record = document.records.remove(at: index)
        document.records.append(record); revision &+= 1
        return record.options
    }
    public func set(_ options: ViewOptions, for location: Location) throws {
        try checkWritable()
        let key = Self.stableKey(for: location)
        document.records.removeAll { $0.key == key }
        if capacity > 0 { document.records.append(LocationOptionsRecord(key: key, options: options)) }
        if count > capacity { document.records.removeFirst(count - capacity) }
        revision &+= 1
    }
    /// Existing overrides remain; unconfigured locations inherit the new defaults immediately.
    public func useAsDefaults(_ options: ViewOptions) throws {
        try checkWritable(); document.defaults = options; revision &+= 1
    }
    public func useAsDefaults(for location: Location) throws {
        try checkWritable(); try useAsDefaults(options(for: location))
    }
    /// No existence probes: offline volumes retain their records unless explicitly supplied here.
    public func removeRecords(forVanishedLocations locations: [Location]) throws {
        try checkWritable()
        let keys = Set(locations.map(Self.stableKey))
        document.records.removeAll { keys.contains($0.key) }; revision &+= 1
    }
    public func flush() async throws {
        let capturedDocument = document
        let capturedRevision = revision
        if let beforeSave { await beforeSave(capturedRevision) }
        try await file.save(capturedDocument, revision: capturedRevision)
    }
    private func checkWritable() throws {
        if isReadOnly { throw PreferenceDocumentError.recoveryReadOnly }
    }
}
