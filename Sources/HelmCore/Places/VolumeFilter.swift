import Foundation

/// Metadata is read once by a provider, never by the sort comparator (F-031, B-058).
public struct VolumeInfo: Hashable, Sendable {
    public let url: URL
    public let name: String
    public let uuid: String?
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isBrowsable: Bool
    public let isHidden: Bool
    public init(url: URL, name: String, uuid: String? = nil, isInternal: Bool = false,
                isRemovable: Bool = false, isBrowsable: Bool = true, isHidden: Bool = false) {
        self.url = url.standardizedFileURL; self.name = name; self.uuid = uuid
        self.isInternal = isInternal; self.isRemovable = isRemovable
        self.isBrowsable = isBrowsable; self.isHidden = isHidden
    }
}

/// Preserves UUID/internal-name dedupe while retaining "VM Images" (F-031, B-080).
public enum VolumeFilter {
    public static func filtered(_ volumes: [VolumeInfo], showAll: Bool = false) -> [VolumeInfo] {
        var identities: Set<String> = []
        var internalNames: Set<String> = []
        return volumes.filter { volume in
            let name = volume.name.lowercased()
            if !showAll {
                guard volume.isBrowsable, !volume.isHidden else { return false }
                let path = volume.url.path
                guard !["/System/Volumes/", "/private/", "/dev/"].contains(where: path.hasPrefix),
                      !["preboot", "recovery", "vm", "update", "hardware", "xarts"].contains(name),
                      !name.hasSuffix(" - data") else { return false }
            }
            guard identities.insert(volume.uuid ?? volume.url.path).inserted else { return false }
            if !showAll && volume.isInternal && !internalNames.insert(name).inserted { return false }
            return true
        }.sorted {
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }
}
