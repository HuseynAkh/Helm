// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Ordered Helm catalogue, separate from file metadata and stars (F-029, M18).
/// Names are case-folded for identity; the first discovered spelling and colour win.
@MainActor public final class TagCatalogStore {
    public private(set) var tags: [FinderTag]
    public let recoveryBackupURL: URL?
    public var isReadOnly: Bool { recoveryBackupURL != nil }
    private let file: PreferenceDocumentFile<[FinderTag]>
    private var revision: UInt64 = 0

    public init(url: URL) async throws {
        let file = PreferenceDocumentFile<[FinderTag]>(url: url)
        self.file = file
        let loaded = try await file.load(defaults: Self.defaultTags) { data in
            let version = try JSONDecoder().decode(PreferenceDocumentHeader.self, from: data).schemaVersion
            switch version {
            case 0:
                // Draft v0 stored Finder raw strings; v1 uses the shared Codable value.
                return try JSONDecoder().decode(VersionedDocument<[String]>.self, from: data).items.map { FinderTag(rawValue: $0) }
            case 1: return try JSONDecoder().decode(VersionedDocument<[FinderTag]>.self, from: data).items
            default: throw PersistenceError.unsupportedVersion(version)
            }
        }
        tags = Self.unique(loaded.0)
        recoveryBackupURL = loaded.1
    }

    public static var defaultTags: [FinderTag] {
        [FinderTag(name: "Red", colorIndex: 6), FinderTag(name: "Orange", colorIndex: 7),
         FinderTag(name: "Yellow", colorIndex: 5), FinderTag(name: "Green", colorIndex: 2),
         FinderTag(name: "Blue", colorIndex: 4), FinderTag(name: "Purple", colorIndex: 3),
         FinderTag(name: "Gray", colorIndex: 1)]
    }

    public func merge(discovered: [FinderTag]) throws {
        try checkWritable()
        tags = Self.unique(tags + discovered); revision &+= 1
    }
    public func rename(_ name: String, to newName: String) throws {
        try checkWritable()
        guard Self.valid(newName) else { throw PreferenceDocumentError.invalidTagName }
        let index = try index(of: name)
        guard !tags.enumerated().contains(where: { $0.offset != index && Self.key($0.element.name) == Self.key(newName) }) else {
            throw PreferenceDocumentError.duplicateTagName
        }
        let old = tags[index]
        // Preserve even malformed or unknown colour suffixes during a rename.
        let suffix = old.rawValue.dropFirst(old.name.count)
        tags[index] = FinderTag(rawValue: newName + suffix); revision &+= 1
    }
    public func recolor(_ name: String, color: FinderTagColor) throws {
        try checkWritable()
        let index = try index(of: name)
        tags[index] = FinderTag(name: tags[index].name, colorIndex: color.rawValue); revision &+= 1
    }
    public func delete(_ name: String) throws {
        try checkWritable(); tags.remove(at: try index(of: name)); revision &+= 1
    }
    /// Requires an exact permutation, preventing accidental loss from stale UI lists.
    public func reorder(names: [String]) throws {
        try checkWritable()
        let keys = names.map(Self.key)
        guard keys.count == tags.count, Set(keys).count == tags.count,
              Set(keys) == Set(tags.map { Self.key($0.name) }) else { throw PreferenceDocumentError.invalidOrder }
        let values = Dictionary(uniqueKeysWithValues: tags.map { (Self.key($0.name), $0) })
        tags = keys.compactMap { values[$0] }; revision &+= 1
    }
    public func flush() async throws { try await file.save(tags, revision: revision) }

    private func checkWritable() throws {
        if isReadOnly { throw PreferenceDocumentError.recoveryReadOnly }
    }
    private func index(of name: String) throws -> Int {
        guard let index = tags.firstIndex(where: { Self.key($0.name) == Self.key(name) }) else {
            throw PreferenceDocumentError.tagNotFound
        }
        return index
    }
    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func valid(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !name.contains("\n") && !name.contains("\0")
    }
    private static func unique(_ tags: [FinderTag]) -> [FinderTag] {
        var seen: Set<String> = []
        return tags.filter { valid($0.name) && seen.insert(key($0.name)).inserted }
    }
}
