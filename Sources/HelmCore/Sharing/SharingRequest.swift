// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Share keeps the explicit, ordered selection of F-063; remote authorities are rejected.
public struct SharingSelectionSnapshot: Equatable, Sendable {
    public let urls: [URL]
    public init(urls: [URL]) throws {
        var seen: Set<[[UInt8]]> = []
        var result: [URL] = []
        for url in urls {
            guard let path = LexicalLocalPath(url) else {
                throw SharingFailure.nonLocalURL(url)
            }
            // Keep the first action URL verbatim; never collapse symlink/.. spellings.
            if seen.insert(path.key).inserted { result.append(url) }
        }
        self.urls = result
    }
}

/// Share/AirDrop availability comes from the host, as F-063 services are platform-owned.
public struct SharingCapability: Equatable, Sendable {
    public let share: Bool
    public let airDrop: Bool
    public init(share: Bool = false, airDrop: Bool = false) {
        self.share = share
        self.airDrop = airDrop
    }
    public func supports(_ kind: SharingKind) -> Bool { kind == .share ? share : airDrop }
}

/// Explicit Share or AirDrop invocation; neither selects a recipient (F-063).
public enum SharingKind: Equatable, Sendable { case share, airDrop }
/// Failure remains distinct from cancellation and provider-reported completion (F-063).
public enum SharingFailure: Error, Equatable, Sendable {
    case nonLocalURL(URL), unsupported, provider(String)
}
/// Immutable request identity prevents later selection changes retargeting Share (F-063).
public struct SharingRequest: Equatable, Sendable {
    public let id: UUID
    public let kind: SharingKind
    public let selection: SharingSelectionSnapshot
    public init(kind: SharingKind, selection: SharingSelectionSnapshot) {
        self.id = UUID()
        self.kind = kind
        self.selection = selection
    }
}
