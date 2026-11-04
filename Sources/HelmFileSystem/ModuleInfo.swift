// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
/// Portable filesystem services preserve listings, templates and monitor refresh (F-035, F-057, B-073).
/// DRAFT: pending Opus compile-correctness and behaviour review after 22:00 Toronto, 2026-11-04.
///
/// Integration notes:
/// - DirectoryLoader.snapshot returns sorted FileEntry values; SnapshotStamp.loadAction wraps them
///   with their load generation. The tab reducer allocates accepted presentation IDs.
/// - LiveFileSystem accepts mount roots for I/O queue isolation and a per-entry diagnostic callback.
///   Wire diagnostics to UI read warnings; directory-open and child metadata failures are thrown.
/// - ListingCache.startMemoryPressureObservation is an explicit composition-root lifecycle call.
/// - A timed-out blocking kernel mutation may still complete. Reconcile before retrying; a quarantined
///   executor volume remains unavailable for that executor instance.
/// - macOS-only FSEvents, vnode, Trash, alias and resource-key paths need Xcode/macOS verification.
///   Linux Trash/alias mutations deliberately report unsupported; they never simulate destructive trash.
/// - FileEntry.cloudAvailability is Core-owned. Listings use K9 metadata inspection; unknown
///   covers unreported/provider metadata and inspection failures. Contents are never read.
/// - isCaseSensitive queries volume semantics. Only collision(noMutation: true) permits retries;
///   generic copy/move collisions may follow partial mutation and never promise safe retry.
public enum HelmFileSystemModule { public static let name: String = "HelmFileSystem" }
