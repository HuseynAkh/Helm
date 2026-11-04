// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Reads mounts off the UI actor and preserves Devices filtering and deduplication (F-031, B-080).
/// Mount notifications and icons remain UI responsibilities.
public struct VolumeReader: Sendable {
    private let executor: IOExecutor
    public init(executor: IOExecutor = IOExecutor()) { self.executor = executor }
    public func volumes(showAll: Bool = false) async throws -> [VolumeInfo] {
        let values: [VolumeDetails] = try await details()
        return VolumeFilter.filtered(values.map(\.volume), showAll: showAll)
    }

    /// Unfiltered mounted metadata; Linux exposes a synthetic root with unknown ejectability.
    public func details() async throws -> [VolumeDetails] {
        try await executor.run {
            #if os(macOS)
            let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsInternalKey,
                .volumeIsRemovableKey, .volumeIsBrowsableKey, .isHiddenKey, .volumeIsEjectableKey]
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) ?? []
            return try urls.map { url in
                let values = try url.resourceValues(forKeys: keys)
                let volume = VolumeInfo(url: url, name: values.volumeName ?? url.lastPathComponent,
                    uuid: values.volumeUUIDString, isInternal: values.volumeIsInternal ?? false,
                    isRemovable: values.volumeIsRemovable ?? false, isBrowsable: values.volumeIsBrowsable ?? true,
                    isHidden: values.isHidden ?? false)
                return VolumeDetails(volume: volume, isEjectable: values.volumeIsEjectable)
            }
            #else
            // Portable fallback exposes only root, not Linux pseudo-filesystems.
            return [VolumeDetails(volume: VolumeInfo(url: URL(fileURLWithPath: "/"), name: "/", isInternal: true),
                                  isEjectable: nil)]
            #endif
        }
    }
}
