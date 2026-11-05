// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// WindowStore adapter for F-008/F-035 monitor validation and cancellation (B-014/B-073).
/// Use one instance per window; supply current view options and forward unrelated effects to the host.
@MainActor public final class DirectoryEffectRunner: EffectRunner {
    private struct Watch {
        let id = UUID()
        let lifetime: UUID
        let location: Location
        let generation: Generation
        let coalescer: DirectoryReloadCoalescer
    }
    private let monitorFactory: @MainActor (Location) -> (any DirectoryMonitor)?
    private let retryDelay: @Sendable (Int) async throws -> Void
    private let snapshotWorker = MonitorSnapshotWorker()
    private let loader: DirectoryLoader
    private let options: @MainActor (TabID) -> LoadOptions
    private let fallback: (any EffectRunner)?
    private var watches: [TabID: Watch] = [:]
    public init(loader: DirectoryLoader, options: @escaping @MainActor (TabID) -> LoadOptions = { _ in LoadOptions() },
                fallback: (any EffectRunner)? = nil,
                monitorFactory: (@MainActor (Location) -> (any DirectoryMonitor)?)? = nil,
                retryDelay: @escaping @Sendable (Int) async throws -> Void = { attempt in
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 250_000_000)
                }) {
        self.loader = loader; self.options = options; self.fallback = fallback
        self.monitorFactory = monitorFactory ?? { loader.monitor($0) }
        self.retryDelay = retryDelay
    }

    public func run(_ effect: StoreEffect,
                    send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation? {
        guard case .tab(let tab, let action) = effect else { return fallback?.run(effect, send: send) }
        switch action {
        case .startMonitor(let location, let generation):
            guard let monitor = monitorFactory(location) else { return nil }
            let initial = Watch(lifetime: UUID(), location: location, generation: generation,
                                coalescer: DirectoryReloadCoalescer(generation: generation))
            watches[tab] = initial
            let task = Task {
                await watch(tab, initial: initial, monitor: monitor, send: send)
            }
            return StoreEffectCancellation { [weak self] in
                task.cancel()
                if self?.watches[tab]?.lifetime == initial.lifetime { self?.watches[tab] = nil }
            }
        case .refreshPaths(_, let generation):
            guard let watch = watches[tab], watch.generation == generation else { return nil }
            return reload(tab, watch: watch, validate: false, send: send)
        case .validateNavigation(let location, let generation):
            guard let watch = watches[tab], watch.generation == generation, watch.location == location else { return nil }
            return reload(tab, watch: watch, validate: true, send: send)
        default: return fallback?.run(effect, send: send)
        }
    }
    // Three attempts per owned monitor lifetime; an exhausted watch is retired and visibly degraded.
    // Each attempt owns a new coalescer and handle, including finite-source termination.
    private func watch(_ tab: TabID, initial: Watch, monitor initialMonitor: any DirectoryMonitor,
                       send: @escaping @Sendable (WindowStoreAction) -> Void) async {
        var watch = initial
        var monitor = initialMonitor
        for attempt in 0..<3 {
            var failure: LoadError = .other("Directory monitor ended")
            do {
                try Task.checkCancellation()
                try await monitor.start()
                try Task.checkCancellation()
                send(.tab(tab, .monitorWatching(watch.generation)))
                if attempt > 0 { send(.tab(tab, .monitorEvent(watch.generation, .rootChanged))) }
                let coalescer = watch.coalescer
                let events = monitor.events
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await coalescer.consume(events) }
                    group.addTask {
                        for await action in coalescer.actions {
                            guard !Task.isCancelled else { break }
                            send(.tab(tab, action))
                        }
                    }
                    await group.waitForAll()
                }
            } catch { failure = .other(String(describing: error)) }
            await watch.coalescer.finish()
            await monitor.stop()
            guard !Task.isCancelled, watches[tab]?.id == watch.id else { return }
            watches[tab] = nil
            let retrying = attempt < 2
            send(.tab(tab, .monitorStopped(watch.generation, failure, retrying: retrying)))
            guard retrying else { return }
            do { try await retryDelay(attempt + 1); try Task.checkCancellation() }
            catch { return }
            guard watches[tab] == nil else { return }
            guard let replacement = monitorFactory(watch.location) else {
                send(.tab(tab, .monitorStopped(watch.generation, failure, retrying: false)))
                return
            }
            watch = Watch(lifetime: initial.lifetime, location: watch.location, generation: watch.generation,
                          coalescer: DirectoryReloadCoalescer(generation: watch.generation))
            monitor = replacement
            watches[tab] = watch
        }
    }

    private func reload(_ tab: TabID, watch: Watch, validate: Bool,
                        send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation {
        let loader = loader
        let snapshotWorker = snapshotWorker
        let current = options(tab)
        let loadOptions = LoadOptions(showHidden: current.showHidden, sort: current.sort, useCache: false, batchSize: current.batchSize)
        let task = Task {
            let revision = await watch.coalescer.rootValidationRevision
            do {
                let entries = try await loader.snapshot(watch.location, options: loadOptions)
                try Task.checkCancellation()
                guard self.watches[tab]?.id == watch.id else { return }
                if validate {
                    guard await watch.coalescer.acknowledgeRootValidation(revision: revision) else { return }
                    try Task.checkCancellation()
                }
                let snapshot = try await snapshotWorker.build(location: watch.location, sortedEntries: entries, sort: loadOptions.sort)
                try Task.checkCancellation()
                guard self.watches[tab]?.id == watch.id else { return }
                send(.tab(tab, .monitorSnapshot(watch.generation, snapshot)))
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                // Always terminate an admitted read with its error. The store's captured
                // request identity rejects it if watch cleanup/replacement already retired it.
                // Failure remains sticky until the host retires/replaces this watch. Do not
                // emit unavailable here: that would recursively request validation forever.
                send(.tab(tab, .monitorValidationFailed(watch.generation, .other(String(describing: error)))))
            }
        }
        return StoreEffectCancellation { task.cancel() }
    }
}
