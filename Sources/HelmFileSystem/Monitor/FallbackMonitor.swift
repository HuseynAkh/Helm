// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Selects native path events, vnode events, then portable polling (B-015).
public actor FallbackMonitor: DirectoryMonitor {
    public nonisolated let events: AsyncStream<MonitorEvent>
    private let continuation: AsyncStream<MonitorEvent>.Continuation
    private let directory: URL
    private let fileSystem: any FileSystem
    private var selected: (any DirectoryMonitor)?
    private var forwarding: Task<Void, Never>?
    private var stopped = false
    private var starting = false
    private var coalescer = EventCoalescer()
    private var flushTask: Task<Void, Never>?
    public private(set) var mechanism: String = "inactive"
    public init(directory: URL, fileSystem: any FileSystem) {
        self.directory = directory; self.fileSystem = fileSystem
        let pair = AsyncStream<MonitorEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
    }
    public func start() async throws {
        guard selected == nil && !stopped && !starting else { return }
        starting = true
        defer { starting = false }
        var candidates: [(String, any DirectoryMonitor)] = []
        #if os(macOS)
        #if canImport(CoreServices)
        candidates.append(("FSEvents", FSEventsMonitor(directory: directory)))
        #endif
        candidates.append(("vnode", DispatchSourceMonitor(directory: directory)))
        #endif
        candidates.append(("polling", PollingMonitor(directory: directory, fileSystem: fileSystem)))
        var lastError: Error = FileSystemError.unsupported
        for (name, monitor) in candidates {
            do {
                try await monitor.start()
                guard !stopped else { await monitor.stop(); return }
                selected = monitor; mechanism = name
                flushTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                        await self?.flush()
                    }
                }
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
    }
    private func flush() {
        guard !stopped else { return }
        for event in coalescer.flushIfDue() { continuation.yield(event) }
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
