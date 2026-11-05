// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Selects native path events, vnode events, then portable polling (B-015).
/// FSEvents and vnode only see changes made through the local kernel, so remote volumes poll instead (FB1-10).
public actor FallbackMonitor: DirectoryMonitor {
    public nonisolated let events: AsyncStream<MonitorEvent>
    private let continuation: AsyncStream<MonitorEvent>.Continuation
    private let directory: URL
    private let fileSystem: any FileSystem
    private let isLocalVolume: @Sendable (URL) async -> Bool
    private var selected: (any DirectoryMonitor)?
    private var forwarding: Task<Void, Never>?
    private var stopped = false
    private var starting = false
    private var coalescer = EventCoalescer()
    private var flushTask: Task<Void, Never>?
    public private(set) var mechanism: String = "inactive"
    public init(directory: URL, fileSystem: any FileSystem) {
        self.init(directory: directory, fileSystem: fileSystem, isLocalVolume: { await FallbackMonitor.volumeIsLocal($0) })
    }
    init(directory: URL, fileSystem: any FileSystem, isLocalVolume: @escaping @Sendable (URL) async -> Bool) {
        self.directory = directory; self.fileSystem = fileSystem; self.isLocalVolume = isLocalVolume
        let pair = AsyncStream<MonitorEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
    }
    #if os(macOS)
    private static let volumeProbe = IOExecutor(timeout: 2)
    #endif
    /// A mount that cannot answer within the probe's deadline is treated as remote.
    static func volumeIsLocal(_ url: URL) async -> Bool {
        #if os(macOS)
        return (try? await volumeProbe.runRead(volume: url.path) {
            try url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal ?? true
        }) ?? false
        #else
        return true
        #endif
    }
    public func start() async throws {
        guard selected == nil && !stopped && !starting else { return }
        starting = true
        defer { starting = false }
        var candidates: [(String, any DirectoryMonitor)] = []
        #if os(macOS)
        let local = await isLocalVolume(directory)
        guard !stopped else { return }
        if local {
            #if canImport(CoreServices)
            candidates.append(("FSEvents", FSEventsMonitor(directory: directory)))
            #endif
            candidates.append(("vnode", DispatchSourceMonitor(directory: directory)))
        }
        #endif
        candidates.append(("polling", PollingMonitor(directory: directory, fileSystem: fileSystem)))
        var lastError: Error = FileSystemError.unsupported
        for (name, monitor) in candidates {
            do {
                try await monitor.start()
                guard !stopped else { await monitor.stop(); return }
                selected = monitor; mechanism = name
                forwarding = Task { [weak self] in
                    for await event in monitor.events {
                        if Task.isCancelled { break }
                        await self?.receive(event)
                    }
                    if !Task.isCancelled { await self?.stop() }
                }
                return
            } catch { lastError = error; await monitor.stop() }
        }
        throw lastError
    }
    private func receive(_ event: MonitorEvent) {
        guard !stopped else { return }
        for event in coalescer.receive(event) { continuation.yield(event) }
        if coalescer.hasPending { scheduleFlush() }
    }
    // Runs only while events wait, so an idle tab holds no 50 ms timer.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                guard let self, await self.flushAndContinue() else { return }
            }
        }
    }
    private func flushAndContinue() -> Bool {
        guard !stopped else { flushTask = nil; return false }
        for event in coalescer.flushIfDue() { continuation.yield(event) }
        if coalescer.hasPending { return true }
        flushTask = nil
        return false
    }
    public func stop() async {
        stopped = true; forwarding?.cancel(); forwarding = nil; flushTask?.cancel(); flushTask = nil
        let monitor = selected; selected = nil; mechanism = "inactive"
        await monitor?.stop(); continuation.finish()
    }
    deinit {
        forwarding?.cancel(); flushTask?.cancel(); continuation.finish()
        if let monitor = selected { Task { await monitor.stop() } }
    }
}
