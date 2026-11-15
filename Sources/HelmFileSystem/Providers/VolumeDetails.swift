import Foundation
import HelmCore

/// F-031 volume metadata supplement; an unknown ejectability never authorizes ejecting a disk.
/// Existing hidden/browsable/removable/internal flags remain available on volume.
public struct VolumeDetails: Hashable, Sendable {
    public let volume: VolumeInfo
    public let isEjectable: Bool?

    public init(volume: VolumeInfo, isEjectable: Bool?) {
        self.volume = volume
        self.isEjectable = isEjectable
    }
}
