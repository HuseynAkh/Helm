// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
#if canImport(Darwin)
import Darwin
#endif

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
    /// The disk's own mark comes first: every provider's file that is on this Mac in name only carries it, where the
    /// iCloud keys are only certain for iCloud. Then the keys, as before.
    static func readMetadata(at url: URL) throws -> CloudAvailability {
        try readMetadata(at: url, isDataless: isDataless)
    }
    /// `isDataless` answers whether the item itself carries the mark; tests stand in for the disk here.
    static func readMetadata(at url: URL, isDataless: (URL) -> Bool) throws -> CloudAvailability {
        if isDataless(url) { return .evicted }
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
    /// Whether the item at `url`, never what a link there points at, is on this Mac in name only: a file that isn't
    /// downloaded, or a folder whose names aren't loaded. Reading the flags reads no contents and loads nothing.
    static let isDataless: @Sendable (URL) -> Bool = { url in
        #if canImport(Darwin)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
        #else
        return false
        #endif
    }
}
