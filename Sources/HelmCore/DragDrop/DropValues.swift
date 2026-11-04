// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Explicit event snapshot preserves F-067 while fixing modifier races (B-045, P-274).
public struct DropModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let option = DropModifiers(rawValue: 1)
    public static let command = DropModifiers(rawValue: 2)
    public static let control = DropModifiers(rawValue: 4)
}
/// Pure operation intent; execution belongs to the journal (F-067, B-044).
public enum DropOperation: String, Hashable, Sendable { case copy, move, alias, moveToTrash }
/// Cursor feedback for F-067 and P-274; rejected proposals never highlight a target.
public enum DropFeedback: String, Hashable, Sendable { case copy, move, alias, trash, forbidden }
/// Stable row identity avoids stale index targets (B-009) and insertion gaps (B-074).
public enum DropHighlight: Hashable, Sendable { case row(ItemID), background, none }
/// Preflight refusal reasons for F-067, B-031, B-040 and P-140.
public enum DropRejection: Hashable, Sendable {
    case emptySources, invalidFileURL, identityMismatch, virtualDestination, readOnlyDestination
    case notDirectory, packageContentsDisallowed, intoItself, intoDescendant, sameParentNoOp
    case overlappingSources, unsupportedOperation
}
/// Snapshot source values preserve file URLs and identities (F-067, P-269).
public struct DraggedItem: Hashable, Sendable {
    public let url: URL
    public let id: ItemID
    public let volumeID: String?
    public init(url: URL, id: ItemID? = nil, volumeID: String? = nil) {
        self.url = url; self.id = id ?? ItemID(url: url); self.volumeID = volumeID
    }
    public init(entry: FileEntry) {
        self.init(url: entry.url, id: entry.id, volumeID: entry.volumeIdentifier)
    }
}
/// Resolved target metadata for F-067; search is an overlay, never a mutation target (B-031).
public struct DropDestination: Hashable, Sendable {
    public let location: Location
    public let volumeID: String?
    public let isDirectory: Bool
    public let isWritable: Bool
    public let isPackage: Bool
    public let allowsPackageContents: Bool
    public let isSearchResults: Bool
    public let highlight: DropHighlight
    public init(location: Location, volumeID: String? = nil, isDirectory: Bool = true,
                isWritable: Bool = true, isPackage: Bool = false, allowsPackageContents: Bool = false,
                isSearchResults: Bool = false, highlight: DropHighlight = .background) {
        self.location = location; self.volumeID = volumeID; self.isDirectory = isDirectory
        self.isWritable = isWritable; self.isPackage = isPackage
        self.allowsPackageContents = allowsPackageContents; self.isSearchResults = isSearchResults
        self.highlight = highlight
    }
}
/// Retain this immutable proposal between validation and acceptance (F-067, B-045).
public struct DropProposal: Hashable, Sendable {
    public let sources: [DraggedItem]
    public let destination: DropDestination
    public let operation: DropOperation?
    public let rejection: DropRejection?
    public var feedback: DropFeedback {
        switch operation {
        case .copy: return .copy
        case .move: return .move
        case .alias: return .alias
        case .moveToTrash: return .trash
        case nil: return .forbidden
        }
    }
    public var highlight: DropHighlight { operation == nil ? .none : destination.highlight }
    public init(sources: [DraggedItem], destination: DropDestination,
                result: Result<DropOperation, DropRejection>) {
        self.sources = sources; self.destination = destination
        switch result {
        case .success(let operation): self.operation = operation; self.rejection = nil
        case .failure(let rejection): self.operation = nil; self.rejection = rejection
        }
    }
}
extension DropRejection: Error {}
