// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Local adapter value for persisted F-060 exact origins; avoids a FileSystem→Persistence dependency.
public struct PutBackOrigin: Equatable, Sendable {
    public let trashedURL: URL
    public let originalURL: URL
    public init(trashedURL: URL, originalURL: URL) { self.trashedURL = trashedURL; self.originalURL = originalURL }
}

/// Explicit root availability prevents denied Trash roots appearing empty (F-032, B-087/B-109).
public struct TrashLocation: Equatable, Sendable {
    public enum Availability: Equatable, Sendable { case available, unmounted, denied, unavailable(String) }
    public let root: URL
    public let volumeRoot: URL
    public let availability: Availability
    public init(root: URL, volumeRoot: URL, availability: Availability) {
        self.root = root; self.volumeRoot = volumeRoot; self.availability = availability
    }
    public static func home(_ home: URL, availability: Availability = .available) -> TrashLocation {
        TrashLocation(root: home.appendingPathComponent(".Trash"), volumeRoot: URL(fileURLWithPath: "/"), availability: availability)
    }
    public static func volume(_ volume: URL, userID: UInt32, availability: Availability = .available) -> TrashLocation {
        TrashLocation(root: volume.appendingPathComponent(".Trashes").appendingPathComponent(String(userID)),
                      volumeRoot: volume, availability: availability)
    }
    public static func cloud(_ cloudRoot: URL, availability: Availability = .available) -> TrashLocation {
        TrashLocation(root: cloudRoot.appendingPathComponent(".Trash"), volumeRoot: cloudRoot, availability: availability)
    }
}

/// Parent state distinguishes disappearance, denial and volume loss for F-060/B-109.
public enum PutBackParentState: Equatable, Sendable { case exists, missing, denied, volumeUnavailable }
/// Restore choices preserve recorded origins and never invent Finder origins (F-060).
public enum PutBackDecision: Equatable, Sendable {
    case restore(source: URL, destination: URL)
    case missingParent(source: URL, originalDestination: URL, suggestedDestination: URL)
    case unavailable(PutBackParentState)
    case unknownOrigin, ambiguousOrigin, invalidPath
}

/// Pure F-060 restoration planning; missing-parent decision offers recreate or choose in UI.
/// Call once per item with reserved destination names added to occupiedNames; revalidate before moving.
public enum PutBackPlanner {
    public static func plan(item: URL, origins: [PutBackOrigin], parent: PutBackParentState,
                            occupiedNames: Set<String> = [], caseSensitive: Bool = false) -> PutBackDecision {
        guard ArchivePlanner.validFileURL(item), item.path != "/", !item.path.contains("\0") else { return .invalidPath }
        let source = item.standardizedFileURL
        let records = origins.filter { ArchivePlanner.validFileURL($0.trashedURL) && $0.trashedURL.standardizedFileURL.path == source.path }
        guard let record = records.first else { return .unknownOrigin }
        // Validate every matching record before reducing URLs to paths; otherwise a remote
        // authority can hide behind an equivalent local path depending on input order.
        guard records.allSatisfy({ record in
            let url = record.originalURL.standardizedFileURL
            return ArchivePlanner.validFileURL(record.originalURL) && url.path != "/"
                && !url.path.contains("\0") && url.path != source.path
                && !url.path.hasPrefix(source.path + "/")
        }) else { return .invalidPath }
        let destinations = Set(records.map { $0.originalURL.standardizedFileURL.path })
        guard destinations.count == 1 else { return .ambiguousOrigin }
        let original = record.originalURL.standardizedFileURL
        guard ArchivePlanner.validFileURL(record.originalURL), original.path != "/", !original.path.contains("\0"), original.path != source.path,
              !original.path.hasPrefix(source.path + "/"),
              let name = try? UniqueNamer.name(for: original.lastPathComponent, existingNames: occupiedNames, caseSensitive: caseSensitive).value else {
            return .invalidPath
        }
        let destination = original.deletingLastPathComponent().appendingPathComponent(name)
        switch parent {
        case .denied, .volumeUnavailable: return .unavailable(parent)
        case .missing: return .missingParent(source: source, originalDestination: original, suggestedDestination: destination)
        case .exists: return .restore(source: source, destination: destination)
        }
    }
}
