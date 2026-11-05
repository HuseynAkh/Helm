// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// WindowStore adapter for F-008/F-035 monitor validation and cancellation (B-014/B-073).
/// Use one instance per window; supply current view options and forward unrelated effects to the host.
@MainActor public final class DirectoryEffectRunner: EffectRunner {
    private struct Watch {
        let location: Location
        let generation: Generation
        let coalescer: DirectoryReloadCoalescer
    }
    private let loader: DirectoryLoader
    private let options: @MainActor (TabID) -> LoadOptions
    private let fallback: (any EffectRunner)?
    private var watches: [TabID: Watch] = [:]
    public init(loader: DirectoryLoader, options: @escaping @MainActor (TabID) -> LoadOptions = { _ in LoadOptions() },
                fallback: (any EffectRunner)? = nil) {
        self.loader = loader; self.options = options; self.fallback = fallback
    }

    public func run(_ effect: StoreEffect,
                    send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation? {
        guard case .tab(let tab, let action) = effect else { return fallback?.run(effect, send: send) }
        switch action {
        case .startMonitor(let location, let generation):
            guard let monitor = loader.monitor(location) else { return nil }
            let coalescer = DirectoryReloadCoalescer(generation: generation)
            watches[tab] = Watch(location: location, generation: generation, coalescer: coalescer)
            let task = Task {
                do {
                    try await monitor.start()
                    try Task.checkCancellation()
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await coalescer.consume(monitor.events) }
                        group.addTask {
                            for await action in coalescer.actions {
                                guard !Task.isCancelled else { break }
                                send(.tab(tab, action))
                            }
                        }
                        await group.waitForAll()
                    }
                } catch {
                    if !Task.isCancelled { send(.tab(tab, .monitorEvent(generation, .unavailable(.other(String(describing: error)))))) }
                }
                await coalescer.finish()
                await monitor.stop()
            }
            return StoreEffectCancellation { [weak self] in
                task.cancel()
                if self?.watches[tab]?.generation == generation { self?.watches[tab] = nil }
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
    private func reload(_ tab: TabID, watch: Watch, validate: Bool,
                        send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation {
        let loader = loader
        let current = options(tab)
        let loadOptions = LoadOptions(showHidden: current.showHidden, sort: current.sort, useCache: false, batchSize: current.batchSize)
        let task = Task {
            let revision = await watch.coalescer.rootValidationRevision
            do {
                let entries = try await loader.snapshot(watch.location, options: loadOptions)
                try Task.checkCancellation()
                if validate {
                    guard await watch.coalescer.acknowledgeRootValidation(revision: revision) else { return }
                    try Task.checkCancellation()
                }
                let snapshot = SnapshotBuilder.build(location: watch.location, entries: entries, sort: loadOptions.sort)
                send(.tab(tab, .monitorSnapshot(watch.generation, snapshot)))
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                // Failure remains sticky until the host retires/replaces this watch. Do not
                // emit unavailable here: that would recursively request validation forever.
                send(.tab(tab, .monitorValidationFailed(watch.generation, .other(String(describing: error)))))
            }
        }
        return StoreEffectCancellation { task.cancel() }
    }
}
