// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Injected read-only F-050 enrichment; nil means unavailable, never an inferred permission grant.
public struct PropertiesSupplement: Sendable {
    public let posixMode: UInt16?
    public let acl: String?
    public let locked: Bool?
    public let imageDimensions: String?
    public let defaultApplication: String?
    public init(posixMode: UInt16? = nil, acl: String? = nil, locked: Bool? = nil,
                imageDimensions: String? = nil, defaultApplication: String? = nil) {
        self.posixMode = posixMode; self.acl = acl; self.locked = locked
        self.imageDimensions = imageDimensions; self.defaultApplication = defaultApplication
    }
}

/// F-050 single/aggregate projection uses Core totals; directories are not recursive totals (B-066).
public struct PropertiesViewModel: Sendable {
    public let entries: [FileEntry]
    public let aggregate: PropertiesModel
    public let supplement: PropertiesSupplement
    public init(entries: [FileEntry], supplement: PropertiesSupplement = PropertiesSupplement()) {
        var seen: Set<ItemID> = []
        let unique = entries.filter { seen.insert($0.id).inserted }
        self.entries = unique; aggregate = PropertiesModel(entries: unique)
        self.supplement = unique.count == 1 ? supplement : PropertiesSupplement()
    }
    public var title: String { entries.count == 1 ? entries[0].name : "\(entries.count) Items" }
    public var kind: String {
        guard !entries.isEmpty else { return "Unknown" }
        return aggregate.commonKindDescription ?? (aggregate.hasMixedKinds ? "Multiple kinds" : "Unknown")
    }
    public var size: String {
        guard !entries.isEmpty else { return "Unknown" }
        if aggregate.sizeOverflowed { return "Size exceeds supported total" }
        let bytes = "\(aggregate.totalSize) bytes"
        let qualifier = aggregate.hasUnknownSize ? " (known sizes only)" : ""
        let directory = aggregate.directoryCount > 0 ? " — folder contents not included" : ""
        return bytes + qualifier + directory
    }
    public var location: String {
        if aggregate.hasMixedLocations { return "Multiple locations" }
        return entries.first?.url.deletingLastPathComponent().path ?? "Unknown"
    }
    public var created: String { dateText(mixed: aggregate.hasMixedCreationDates, date: entries.first?.creationDate) }
    public var modified: String { dateText(mixed: aggregate.hasMixedModificationDates, date: entries.first?.modificationDate) }
    public var contentType: String {
        let values = Set(entries.map(\.contentTypeIdentifier))
        return values.count > 1 ? "Multiple types" : entries.first?.contentTypeIdentifier ?? "Unknown"
    }
    public var permissionRows: [(String, String)] {
        guard let mode = supplement.posixMode else { return [("POSIX", entries.count > 1 ? "Multiple items — unavailable" : "Unavailable")] }
        return [("Owner", Self.permissionText((mode >> 6) & 7)),
                ("Group", Self.permissionText((mode >> 3) & 7)),
                ("Others", Self.permissionText(mode & 7)), ("POSIX", String(mode, radix: 8))]
    }
    public static func permissionText(_ bits: UInt16) -> String {
        let names = [(UInt16(4), "Read"), (UInt16(2), "Write"), (UInt16(1), "Execute")]
            .filter { bits & $0.0 != 0 }.map { $0.1 }
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }
    private func dateText(mixed: Bool, date: Date?) -> String {
        if mixed { return "Multiple dates" }
        guard let date = date, date != .distantPast else { return "Unknown" }
        let formatter = DateFormatter(); formatter.dateStyle = .long; formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
