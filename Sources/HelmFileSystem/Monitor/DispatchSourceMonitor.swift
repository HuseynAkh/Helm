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
            eventMask: [.write, .rename, .delete, .attrib], queue: DispatchQueue.global(qos: .utility))
        let continuation = self.continuation
        watcher.setEventHandler { continuation.yield(.rescan) }
        // Cancellation owns descriptor closure; close must never precede source cancellation.
        watcher.setCancelHandler { _ = close(descriptor) }
        source = watcher
        watcher.resume()
    }
    public func stop() async { source?.cancel(); source = nil; continuation.finish() }
    deinit { source?.cancel(); continuation.finish() }
}
#endif
