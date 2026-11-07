#if os(macOS)
import AppKit
import HelmCore
import HelmFileSystem

/// Drives for the sidebar: mounted volumes, plus iCloud Drive and the cloud drives macOS keeps in `~/Library/CloudStorage`.
/// Reads run off the main actor, one per volume, so a stalled mount can't hang the UI.
@MainActor public final class VolumeCenter {
    public private(set) var volumes: [VolumeInfo] = []
    public let changes: Broadcast<[VolumeInfo]> = Broadcast()
    private let reader = VolumeReader()
    private let showAll: () -> Bool
    private var observers: [NSObjectProtocol] = []
    /// Tests pass no volumes, so a fixture run never reads real mounts.
    private let isLive: Bool

    private let home: URL

    public init(isLive: Bool, home: URL, showAll: @escaping () -> Bool) {
        self.isLive = isLive; self.home = home; self.showAll = showAll
        guard isLive else { reload(); return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }) 
        }
        reload()
    }

    public func reload() {
        let reader = reader, showAll = showAll(), isLive = isLive, home = home
        Task { [weak self] in
            // A fixture run has its own home folder, and never looks at real mounts.
            let mounted = isLive ? ((try? await reader.volumes(showAll: showAll)) ?? []) : []
            let cloud = await Task.detached { Self.cloudDrives(home: home) }.value
            guard let self else { return }
            self.volumes = mounted + cloud
            self.changes.send(self.volumes)
        }
    }

    /// Reads folder names only, so nothing downloads and no provider's files are opened.
    private nonisolated static func cloudDrives(home: URL) -> [VolumeInfo] {
        let manager = FileManager.default
        var drives: [VolumeInfo] = []
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if manager.fileExists(atPath: iCloud.path) {
            drives.append(VolumeInfo(url: iCloud, name: "iCloud Drive", isCloud: true))
        }
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let folders = ((try? manager.contentsOfDirectory(atPath: storage.path)) ?? []).filter { !$0.hasPrefix(".") }
        let names = CloudDriveNaming.names(forFolders: folders)
        for folder in folders.sorted() {
            drives.append(VolumeInfo(url: storage.appendingPathComponent(folder, isDirectory: true), name: names[folder] ?? folder, isCloud: true))
        }
        return drives
    }

    public func eject(_ url: URL) {
        Task.detached {
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
            catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.messageText = "“\(url.lastPathComponent)” couldn’t be ejected."
                    alert.runModal()
                }
            }
        }
    }
}
#endif
