// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Lossless sidebar routing for F-027–F-030; virtual collections are never writable folders.
/// Resolution describes intent, not filesystem availability, and performs no I/O.
public enum ResolvedPlace: Hashable, Sendable {
    case directory(URL)
    case recentCollection
    case starredCollection
    case trashCollection
}
