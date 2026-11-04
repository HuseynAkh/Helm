/// Portable persistence for F-028–F-030, F-060, F-065 and F-068.
/// DRAFT: Opus compile/behaviour review remains required after 22:00 Toronto, 2026-11-04.
///
/// Integration: await LegacyDefaultsMigrator.migrate before constructing stores or registering defaults.
/// Share one instance per document across all windows; invoke flush on quit and before releasing stores.
/// Debounced failures are available through lastError; explicit flush throws. Future schemas block load.
/// PlaceDestination.starred is intentionally not converted to a directory: K1 Location needs a Starred case.
/// VolumeReader currently omits hidden/browsable/removable metadata needed to populate VolumeInfo fully.
/// These cross-lane contracts are left untouched. macOS/Xcode validation remains pending.
public enum HelmPersistenceModule { public static let name: String = "HelmPersistence" }
