// DRAFT: pending review, 2026-11-05
import HelmCore
import HelmPersistence

/// Shared catalogue edits and quit flushing preserve tag identity separately from stars (F-029, F-068).
@MainActor public protocol AppTagCatalogStoring: AppFlushable {
    var tags: [FinderTag] { get }
    func merge(discovered: [FinderTag]) throws
    func rename(_ name: String, to newName: String) throws
    func recolor(_ name: String, color: FinderTagColor) throws
    func delete(_ name: String) throws
    func reorder(names: [String]) throws
}

/// Shared per-location preferences and quit flushing preserve folder views (F-036, F-040, F-065).
@MainActor public protocol AppViewOptionsStoring: AppFlushable {
    var defaults: ViewOptions { get }
    func options(for location: Location) -> ViewOptions
    func set(_ options: ViewOptions, for location: Location) throws
    func useAsDefaults(_ options: ViewOptions) throws
    func useAsDefaults(for location: Location) throws
    func removeRecords(forVanishedLocations locations: [Location]) throws
}

extension TagCatalogStore: AppTagCatalogStoring {}
extension LocationViewOptionsStore: AppViewOptionsStoring {}
