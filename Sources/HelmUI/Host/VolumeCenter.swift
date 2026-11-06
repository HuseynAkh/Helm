#if os(macOS)
import AppKit
import HelmCore
import HelmFileSystem

/// Mounted volumes for the sidebar. Reads run off the main actor, one per volume, so a stalled mount can't hang the UI.
@MainActor public final class VolumeCenter {
    public private(set) var volumes: [VolumeInfo] = []
    public let changes: Broadcast<[VolumeInfo]> = Broadcast()
    private let reader = VolumeReader()
    private let showAll: () -> Bool
    private var observers: [NSObjectProtocol] = []
    /// Tests pass no volumes, so a fixture run never reads real mounts.
    private let isLive: Bool

    public init(isLive: Bool, showAll: @escaping () -> Bool) {
        self.isLive = isLive; self.showAll = showAll
        guard isLive else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }) 
        }
        reload()
    }

    public func reload() {
        guard isLive else { return }
        let reader = reader, showAll = showAll()
        Task { [weak self] in
            let values = (try? await reader.volumes(showAll: showAll)) ?? []
            guard let self else { return }
            self.volumes = values
            self.changes.send(values)
        }
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
