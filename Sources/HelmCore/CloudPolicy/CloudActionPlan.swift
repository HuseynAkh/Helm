// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Injected provider support; cloud metadata alone grants no actions (F-035, F-049).
public struct CloudCapabilities: Equatable, Sendable {
    public let canMaterialize: Bool
    public let canEvict: Bool
    public init(canMaterialize: Bool = false, canEvict: Bool = false) {
        self.canMaterialize = canMaterialize
        self.canEvict = canEvict
    }
}

/// Passive listing/thumbnail demand is distinct from user activation (F-007, F-035, F-049).
public enum CloudAccessPurpose: CaseIterable, Sendable {
    case listing, thumbnail, explicitOpen, explicitPreview
}

/// Admission values only; eviction is a provider request, never deletion or Trash (F-035).
public enum CloudActionPlan: Equatable, Sendable {
    case metadataOnly, suppressThumbnail, useLocalContent
    case requestExplicitMaterialization, awaitMaterialization, requestExplicitEviction, unsupported

    public static func build(entry: FileEntry, purpose: CloudAccessPurpose,
                             capabilities: CloudCapabilities) -> CloudActionPlan {
        guard isLocalURL(entry.url) else { return .unsupported }
        if purpose == .listing { return .metadataOnly }
        if purpose == .thumbnail {
            return entry.cloudAvailability == .local ? .useLocalContent : .suppressThumbnail
        }
        switch entry.cloudAvailability {
        case .local: return .useLocalContent
        case .unknown: return .unsupported
        case .evicted:
            return capabilities.canMaterialize ? .requestExplicitMaterialization : .unsupported
        case .downloading:
            return capabilities.canMaterialize ? .awaitMaterialization : .unsupported
        }
    }

    public static func eviction(entry: FileEntry, explicitlyRequested: Bool,
                                capabilities: CloudCapabilities) -> CloudActionPlan {
        guard explicitlyRequested, capabilities.canEvict, isLocalURL(entry.url),
              entry.cloudAvailability == .local else { return .unsupported }
        return .requestExplicitEviction
    }

    private static func isLocalURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
            && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil && url.path.hasPrefix("/")
    }
}

/// Provider identity is injected, not inferred from a path prefix (F-067).
public enum CloudProviderDomain: Equatable, Sendable {
    case local, provider(String), unknown
}

/// Moving any selected item across a provider boundary requires a warning (F-067).
public enum CloudMoveWarning: Equatable, Sendable {
    case none, confirmProviderBoundary, confirmUnknownBoundary

    public static func build(sources: [CloudProviderDomain], destination: CloudProviderDomain) -> CloudMoveWarning {
        guard !sources.isEmpty else { return .none }
        if destination == .unknown || sources.contains(.unknown) { return .confirmUnknownBoundary }
        return sources.contains(where: { $0 != destination }) ? .confirmProviderBoundary : .none
    }
}
