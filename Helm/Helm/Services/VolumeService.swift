import Foundation
import AppKit
import Combine

@MainActor
final class VolumeService: ObservableObject {

    @Published private(set) var mountedVolumes: [Place] = []
    private var observerTokens: [NSObjectProtocol] = []
    private let systemPathPrefixes: [String] = [
        "/System/Volumes/",
        "/private/",
        "/dev/"
    ]
    private let excludedNameFragments: [String] = [
        "preboot",
        "recovery",
        "vm",
        "update",
        "hardware",
        " xarts", // known helper mount suffixes
        " - data"
    ]

    init() {
        refreshVolumes()
        setupNotifications()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observerTokens.forEach { center.removeObserver($0) }
    }

    private func setupNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        let mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshVolumes()
            }
        }

        let unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshVolumes()
            }
        }

        observerTokens = [mountObserver, unmountObserver]
    }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsBrowsableKey,
            .volumeUUIDStringKey
        ]

        guard let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: AppSettings.showAllMountedVolumes ? [] : [.skipHiddenVolumes]
        ) else {
            mountedVolumes = []
            return
        }

        var seenUUIDs: Set<String> = []
        var seenInternalDisplayNames: Set<String> = []
        var places: [Place] = []

        for url in volumeURLs {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  shouldIncludeVolume(url: url, values: values) else {
                continue
            }

            let volumeUUID = values.volumeUUIDString ?? url.standardizedFileURL.path
            guard !seenUUIDs.contains(volumeUUID) else { continue }
            seenUUIDs.insert(volumeUUID)

            let name = values.volumeName ?? url.lastPathComponent
            let normalizedName = name.lowercased()
            let isInternal = values.volumeIsInternal ?? false

            if !AppSettings.showAllMountedVolumes && isInternal {
                guard !seenInternalDisplayNames.contains(normalizedName) else { continue }
                seenInternalDisplayNames.insert(normalizedName)
            }

            let isRemovable = values.volumeIsRemovable ?? false
            let iconName = isRemovable ? "externaldrive" : "internaldrive"
            let place = Place(
                id: "volume-\(url.path)",
                name: name,
                url: url,
                iconName: iconName,
                kind: .device
            )
            places.append(place)
        }

        mountedVolumes = places.sorted(by: sortDevices)
    }

    private func shouldIncludeVolume(url: URL, values: URLResourceValues) -> Bool {
        guard AppSettings.showAllMountedVolumes else {
            if values.volumeIsBrowsable == false {
                return false
            }

            let path = url.standardizedFileURL.path
            if path != "/" && systemPathPrefixes.contains(where: path.hasPrefix) {
                return false
            }

            let name = (values.volumeName ?? url.lastPathComponent).lowercased()
            if excludedNameFragments.contains(where: { name.contains($0) }) {
                return false
            }
            return true
        }

        return true
    }

    private func sortDevices(_ lhs: Place, _ rhs: Place) -> Bool {
        let lhsInternal = (try? lhs.url.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) ?? false
        let rhsInternal = (try? rhs.url.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) ?? false

        if lhsInternal != rhsInternal {
            // Keep internal/system drive first.
            return lhsInternal && !rhsInternal
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
