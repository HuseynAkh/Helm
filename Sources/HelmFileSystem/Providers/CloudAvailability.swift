// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// F-035 metadata-only cloud inspection off the UI actor; no download requests are issued.
public struct CloudAvailabilityReader: Sendable {
    private let executor: IOExecutor

    public init(executor: IOExecutor = IOExecutor()) { self.executor = executor }

    /// Metadata errors propagate on macOS; Linux cannot determine cloud availability.
    public func availability(at url: URL) async throws -> CloudAvailability {
        try await executor.runRead {
            try Self.readMetadata(at: url)
        }
    }
    /// Shared metadata path for listings already executing off the UI actor (F-035).
    static func readMetadata(at url: URL) throws -> CloudAvailability {
        #if os(macOS)
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isUbiquitousItem == true else { return .unknown }
        if values.ubiquitousItemIsDownloading == true { return .downloading }
        switch values.ubiquitousItemDownloadingStatus {
        case .current?, .downloaded?: return .local
        case .notDownloaded?: return .evicted
        default: return .unknown
        }
        #else
        return .unknown
        #endif
    }
}
