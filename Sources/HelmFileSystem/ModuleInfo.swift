/// Portable filesystem services preserve listings, templates and monitor refresh (F-035, F-057, B-073).
/// DRAFT: pending Opus compile-correctness and behaviour review after 22:00 Toronto, 2026-11-04.
///
/// Integration notes:
/// - DirectoryLoader.snapshot returns sorted FileEntry values. K1 currently has no PresentationSnapshot;
///   the tab lane must stamp snapshot IDs/generations when wrapping these values.
/// - LiveFileSystem accepts mount roots for I/O queue isolation and a per-entry diagnostic callback.
///   Wire diagnostics to UI partial-read warnings; directory-open failures are thrown.
/// - ListingCache.startMemoryPressureObservation is an explicit composition-root lifecycle call.
/// - A timed-out blocking kernel mutation may still complete. Reconcile before retrying; a quarantined
///   executor volume remains unavailable for that executor instance.
/// - macOS-only FSEvents, vnode, Trash, alias and resource-key paths need Xcode/macOS verification.
///   Linux Trash/alias mutations deliberately report unsupported; they never simulate destructive trash.
/// - FileEntry has no tags or cloud-availability fields. Tags stay absent; listings do not read contents.
///   A future Core availability contract is needed before UI can distinguish evicted cloud placeholders.
public enum HelmFileSystemModule { public static let name: String = "HelmFileSystem" }
