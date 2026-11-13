// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Reads mounts off the UI actor and preserves Devices filtering and deduplication (F-031, B-080).
/// Mount notifications and icons remain UI responsibilities.
/// Each volume reads under its own executor key, so one stalled or denied mount cannot hide the others (B-107).
public struct VolumeReader: Sendable {
    private let executor: IOExecutor
    private var injectedURLs: (@Sendable () throws -> [URL])?
    private var injectedRead: (@Sendable (URL) throws -> VolumeDetails)?
    private let diagnostic: @Sendable (URL, FileSystemError) -> Void
    init(mountedURLs: @escaping @Sendable () throws -> [URL],
         readVolume: @escaping @Sendable (URL) throws -> VolumeDetails,
         diagnostic: @escaping @Sendable (URL, FileSystemError) -> Void = { _, _ in }) {
        executor = IOExecutor(); injectedURLs = mountedURLs; injectedRead = readVolume
        self.diagnostic = diagnostic
    }
    public init(executor: IOExecutor = IOExecutor(),
                diagnostic: @escaping @Sendable (URL, FileSystemError) -> Void = { _, _ in }) {
        self.executor = executor; self.diagnostic = diagnostic
    }
    public func volumes(showAll: Bool = false) async throws -> [VolumeInfo] {
        let values: [VolumeDetails] = try await details()
        return VolumeFilter.filtered(values.map(\.volume), showAll: showAll)
    }

    /// Unfiltered mounted metadata in mount-table order; Linux exposes a synthetic root with unknown ejectability.
    /// An unreadable volume is reported through `diagnostic` and omitted. If every volume fails the first failure
    /// is thrown, so a total outage never reads as "no devices" (B-109).
    public func details() async throws -> [VolumeDetails] {
        let urls = try await executor.runRead { try mountedURLs() }
        let outcomes = await withTaskGroup(of: (Int, Result<VolumeDetails, Error>).self,
                                           returning: [(Int, Result<VolumeDetails, Error>)].self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do { return (index, .success(try await executor.runRead(volume: url.path) { try readVolume(url) })) }
                    catch { return (index, .failure(error)) }
                }
            }
            var collected: [(Int, Result<VolumeDetails, Error>)] = []
            for await outcome in group { collected.append(outcome) }
            return collected.sorted { $0.0 < $1.0 }
        }
        try Task.checkCancellation()
        var values: [VolumeDetails] = []
        var firstFailure: Error?
        for (index, outcome) in outcomes {
            switch outcome {
            case .success(let value): values.append(value)
            case .failure(let error):
                if firstFailure == nil { firstFailure = error }
                diagnostic(urls[index], FileSystemError.mapping(error))
            }
        }
        if values.isEmpty, let firstFailure { throw firstFailure }
        return values
    }
    private func mountedURLs() throws -> [URL] {
        if let injectedURLs { return try injectedURLs() }
        #if os(macOS)
        // No pre-fetched keys: caching resource values here could block the whole list on one stale mount.
        return FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        #else
        // Portable fallback exposes only root, not Linux pseudo-filesystems.
        return [URL(fileURLWithPath: "/")]
        #endif
    }
    private func readVolume(_ url: URL) throws -> VolumeDetails {
        if let injectedRead { return try injectedRead(url) }
        #if os(macOS)
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsInternalKey,
            .volumeIsRemovableKey, .volumeIsBrowsableKey, .isHiddenKey, .volumeIsEjectableKey, .volumeIsLocalKey]
        let values = try url.resourceValues(forKeys: keys)
        return Self.details(url: url, name: values.volumeName, uuid: values.volumeUUIDString,
                            isInternal: values.volumeIsInternal, isRemovable: values.volumeIsRemovable,
                            isBrowsable: values.volumeIsBrowsable, isHidden: values.isHidden,
                            isEjectable: values.volumeIsEjectable, isLocal: values.volumeIsLocal)
        #else
        return VolumeDetails(volume: VolumeInfo(url: url, name: "/", isInternal: true), isEjectable: nil)
        #endif
    }
    /// A volume's details from the keys macOS answered; nil is a key it didn't answer. A volume that isn't stored on
    /// this Mac is a share on a server. One that didn't say is taken as local, as before.
    static func details(url: URL, name: String?, uuid: String?, isInternal: Bool?, isRemovable: Bool?,
                        isBrowsable: Bool?, isHidden: Bool?, isEjectable: Bool?, isLocal: Bool?) -> VolumeDetails {
        let volume = VolumeInfo(url: url, name: name ?? url.lastPathComponent, uuid: uuid, isInternal: isInternal ?? false,
                                isRemovable: isRemovable ?? false, isBrowsable: isBrowsable ?? true, isHidden: isHidden ?? false,
                                isNetwork: isLocal == false)
        return VolumeDetails(volume: volume, isEjectable: isEjectable)
    }
}
