// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
#if os(macOS)
import Foundation
import Dispatch
import Darwin
import HelmCore

/// Coarse vnode fallback reports rescans, never invented child paths (B-015).
public actor DispatchSourceMonitor: DirectoryMonitor {
    public nonisolated let events: AsyncStream<MonitorEvent>
    private let continuation: AsyncStream<MonitorEvent>.Continuation
    private let directory: URL
    private var identity: UUID?
    private var source: DispatchSourceFileSystemObject?
    public init(directory: URL) {
        self.directory = directory
        let pair = AsyncStream<MonitorEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
    }
    public func start() async throws {
        guard source == nil else { return }
        // O_EVTONLY and DispatchSourceFileSystemObject are Darwin-only APIs.
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw FileSystemError.mapping(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .revoke], queue: DispatchQueue.global(qos: .utility))
        let identity = UUID()
        self.identity = identity
        watcher.setEventHandler { [weak self] in
            // Dispatch event data must be captured while the handler is executing.
            let flags = watcher.data
            Task { await self?.receive(identity: identity, flags: flags) }
        }
        // Cancellation owns descriptor closure; close must never precede source cancellation.
        watcher.setCancelHandler { _ = close(descriptor) }
        source = watcher
        watcher.resume()
    }
    private func receive(identity: UUID, flags: DispatchSource.FileSystemEvent) {
        guard self.identity == identity else { return }
        if !flags.intersection([.rename, .delete, .revoke]).isEmpty {
            continuation.yield(.rootChanged)
        } else { continuation.yield(.rescan) }
    }
    public func stop() async {
        identity = nil
        source?.setEventHandler(handler: nil); source?.cancel(); source = nil; continuation.finish()
    }
    deinit { source?.setEventHandler(handler: nil); source?.cancel(); continuation.finish() }
}
#endif
