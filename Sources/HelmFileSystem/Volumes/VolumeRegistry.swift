// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Mount lifecycle inputs preserve Devices updates (F-031) without AppKit in the provider.
public enum VolumeEvent: Equatable, Sendable {
    case mounted(VolumeDetails)
    case unmounted(URL)
    case renamed(previousURL: URL, volume: VolumeDetails)
    case ejectFailed(URL, reasons: [String])
}

/// UI supplies live notifications; portable consumers preserve F-031 without owning observers.
public protocol VolumeEventSource: Sendable {
    func events() -> AsyncStream<VolumeEvent>
}

/// Replayable finite notification fixture for F-031, including duplicate notifications.
public struct ScriptedVolumeEventSource: VolumeEventSource {
    public let script: [VolumeEvent]
    public init(script: [VolumeEvent]) { self.script = script }
    public func events() -> AsyncStream<VolumeEvent> {
        AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Ordered changes for F-031; updated includes metadata changes, not merely renamed labels.
public struct VolumeChange: Equatable, Sendable {
    public let inserted: [VolumeDetails]
    public let removed: [VolumeDetails]
    public let updated: [VolumeDetails]
    public let ejectFailure: [String]?
    public init(inserted: [VolumeDetails], removed: [VolumeDetails], updated: [VolumeDetails], ejectFailure: [String]? = nil) {
        self.inserted = inserted; self.removed = removed; self.updated = updated; self.ejectFailure = ejectFailure
    }
}

/// Pure event fold preserves Core's Devices order/filter and UUID dedupe (F-031, B-080).
/// Confine this value to its owning actor; unmounts match paths so late old-path events cannot remove a remount.
public struct VolumeRegistry: Sendable {
    private var mounted: [VolumeDetails]
    public let showAll: Bool
    public init(volumes: [VolumeDetails] = [], showAll: Bool = false) {
        self.mounted = []; self.showAll = showAll
        for volume in volumes { upsert(volume) }
    }
    public var volumes: [VolumeDetails] {
        VolumeFilter.filtered(mounted.map(\.volume), showAll: showAll).compactMap { info in
            mounted.first { $0.volume == info }
        }
    }
    private func identity(_ value: VolumeDetails) -> String { value.volume.uuid ?? value.volume.url.path }
    private mutating func upsert(_ value: VolumeDetails) {
        let key = identity(value)
        mounted.removeAll { ($0.volume.uuid ?? $0.volume.url.path) == key || $0.volume.url.path == value.volume.url.path }
        mounted.append(value)
    }
    @discardableResult public mutating func apply(_ event: VolumeEvent) -> VolumeChange {
        let before = volumes
        var failure: [String]?
        switch event {
        case .mounted(let value): upsert(value)
        case .unmounted(let url): mounted.removeAll { $0.volume.url.path == url.standardizedFileURL.path }
        case .renamed(let previous, let value):
            // A late rename must not resurrect an already unmounted disk.
            if mounted.contains(where: { $0.volume.url.path == previous.standardizedFileURL.path }) {
                mounted.removeAll { $0.volume.url.path == previous.standardizedFileURL.path }; upsert(value)
            }
        case .ejectFailed(_, let reasons): failure = reasons
        }
        let after = volumes
        return VolumeChange(inserted: after.filter { item in !before.contains { identity($0) == identity(item) } },
            removed: before.filter { item in !after.contains { identity($0) == identity(item) } },
            updated: after.filter { item in before.contains { identity($0) == identity(item) && $0 != item } },
            ejectFailure: failure)
    }
}

/// Conservative removal dispositions for F-031/P-202; unknown capability never authorizes eject.
public enum VolumeRemovalOutcome: Equatable, Sendable {
    case ejectable(URL)
    case unmountable(URL)
    case busy(reasons: [String])
    case internalVolumeRefusal
    case unsupported
    case alreadyGone
}

/// Plans safe eject/unmount after callers supply outstanding owned-handle reasons (F-031, B-107).
public enum VolumeRemovalPlanner {
    public static func plan(volume: VolumeDetails?, unmountOnly: Bool = false, busyReasons: [String] = []) -> VolumeRemovalOutcome {
        guard let volume = volume else { return .alreadyGone }
        guard !volume.volume.isInternal, volume.volume.url.path != "/" else { return .internalVolumeRefusal }
        if !busyReasons.isEmpty { return .busy(reasons: busyReasons) }
        if unmountOnly { return .unmountable(volume.volume.url) }
        return volume.isEjectable == true ? .ejectable(volume.volume.url) : .unsupported
    }
}
