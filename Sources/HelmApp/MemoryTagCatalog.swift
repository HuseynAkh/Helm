// DRAFT: pending review, 2026-11-05
import Foundation
import HelmCore
import HelmPersistence

// In-memory counterpart of TagCatalogStore: same admission, identity and ordering (F-029, B-068).
@MainActor final class AppMemoryTagCatalog: AppTagCatalogStoring {
    let isReadOnly = false
    let recoveryBackupURL: URL? = nil
    private(set) var tags: [FinderTag] = TagCatalogStore.defaultTags
    func merge(discovered: [FinderTag]) throws {
        tags = Self.unique(tags + discovered)
    }
    func rename(_ name: String, to newName: String) throws {
        guard Self.valid(newName) else { throw PreferenceDocumentError.invalidTagName }
        let index = try index(of: name)
        guard !tags.enumerated().contains(where: { $0.offset != index && Self.key($0.element.name) == Self.key(newName) }) else {
            throw PreferenceDocumentError.duplicateTagName
        }
        let old = tags[index]
        // Preserve even malformed or unknown colour suffixes during a rename.
        let suffix = old.rawValue.dropFirst(old.name.count)
        tags[index] = FinderTag(rawValue: newName + suffix)
    }
    func recolor(_ name: String, color: FinderTagColor) throws {
        let index = try index(of: name)
        tags[index] = FinderTag(name: tags[index].name, colorIndex: color.rawValue)
    }
    func delete(_ name: String) throws {
        tags.remove(at: try index(of: name))
    }
    /// Requires an exact permutation, preventing accidental loss from stale UI lists.
    func reorder(names: [String]) throws {
        let keys = names.map(Self.key)
        guard keys.count == tags.count, Set(keys).count == tags.count,
              Set(keys) == Set(tags.map { Self.key($0.name) }) else { throw PreferenceDocumentError.invalidOrder }
        let values = Dictionary(uniqueKeysWithValues: tags.map { (Self.key($0.name), $0) })
        tags = keys.compactMap { values[$0] }
    }
    func flush() async throws {}

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
