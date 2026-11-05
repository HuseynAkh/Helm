// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Foundation FIFO store preserves navigation commit/history and tab isolation (F-002/F-005, B-020/B-069).
/// Main-actor send drains synchronously; enqueue admits actions from any context in lock-acquisition order.
/// Every accepted action publishes once, including no-ops. No state/effect coalescing or initial replay occurs.
@MainActor public final class WindowStore {
    public private(set) var state: WindowStoreSnapshot
    public let snapshots: Broadcast<WindowStoreSnapshot>
    private let runner: any EffectRunner
    private let clock: any HelmClock
    private let context: ReducerContext
    private nonisolated let mailbox = StoreMailbox()
    private var draining: Bool = false
    private var stopped: Bool = false
    private var running: [TabID: [GenerationLane: Running]] = [:]
    private var monitorReloads: [TabID: Running] = [:]
    private struct Running {
        let generation: Generation
        let cancellation: StoreEffectCancellation
    }

    /// Missing tab values use the supplied home; extra values are ignored and activity is normalized.
    public init(window: WindowState, tabs: [TabState], runner: any EffectRunner,
                clock: any HelmClock = SystemHelmClock(), context: ReducerContext) {
        self.runner = runner; self.clock = clock; self.context = context
        self.snapshots = Broadcast()
        var values: [TabID: TabState] = [:]
        for tab in tabs where values[tab.id] == nil { values[tab.id] = tab }
        var normalized: [TabID: TabState] = [:]
        for id in window.tabs {
            var tab = values[id] ?? TabState(id: id, location: .directory(context.homeDirectory),
                                            homeDirectory: context.homeDirectory, settings: context.settings)
            tab.isActive = id == window.activeTabID
            normalized[id] = tab
        }
        self.state = WindowStoreSnapshot(window: window, tabs: normalized, sequence: 0, timestamp: clock.now())
    }

    /// Returns after draining on MainActor, except nested calls which only append to the FIFO.
    public func send(_ action: WindowStoreAction) {
        _ = mailbox.append(action)
        drain()
    }

    /// Admission is synchronous; delivery is scheduled on MainActor. Concurrent callers are ordered by admission.
    public nonisolated func enqueue(_ action: WindowStoreAction) {
        guard mailbox.append(action) else { return }
        Task { @MainActor [weak self] in self?.drain() }
    }

    /// Explicit deterministic flush for tests and adapters; never recurses during delivery.
    public func drain() {
        guard !draining, !stopped else { return }
        draining = true
        defer { draining = false }
        while let action = mailbox.pop() {
            apply(action)
            if stopped { break }
        }
    }

    private func apply(_ action: WindowStoreAction) {
        var window = state.window
        var tabs = state.tabs
        var effects: [StoreEffect] = []
        let now = clock.now()
        let sampled = ReducerContext(now: now, homeDirectory: context.homeDirectory,
                                     starredIDs: context.starredIDs, settings: context.settings)
        func reduceTab(_ id: TabID, _ action: TabAction) {
            guard let old = tabs[id] else { return }
            let (next, emitted) = TabReducer.reduce(old, action, context: sampled)
            tabs[id] = next; effects += emitted.map { .tab(id, $0) }
        }
        func reduceWindow(_ action: WindowAction) {
            let (next, emitted) = WindowReducer.reduce(window, action)
            window = next
            for effect in emitted {
                switch effect {
                case .activate(let id): reduceTab(id, .activated)
                case .deactivate(let id): reduceTab(id, .deactivated)
                case .dispose(let id): tabs[id] = nil
                case .closeWindow: break
                }
                effects.append(.window(effect))
            }
        }
        switch action {
        case .tab(let id, let tabAction): reduceTab(id, tabAction)
        case .window(let windowAction):
            // A bare add still needs a matching owned tab value.
            if case .add(let id, _) = windowAction, tabs[id] == nil {
                var tab = TabState(id: id, location: .directory(context.homeDirectory),
                                   homeDirectory: context.homeDirectory, settings: context.settings)
                tab.isActive = false; tabs[id] = tab
            }
            reduceWindow(windowAction)
        case .addTab(var tab, let activate):
            if tabs[tab.id] == nil { tab.isActive = false; tabs[tab.id] = tab }
            reduceWindow(.add(tab.id, activate: activate))
        case .persistSession: break
        case .shutdown: stopped = true; mailbox.close()
        }
        state = WindowStoreSnapshot(window: window, tabs: tabs, sequence: state.sequence &+ 1, timestamp: now)
        snapshots.send(state)
        if stopped { cancelAll(); return }
        if case .persistSession = action { effects.append(.persistSession(state)) }
        for effect in effects { execute(effect) }
    }

    private func execute(_ effect: StoreEffect) {
        if case .window(.dispose(let id)) = effect { cancelTab(id) }
        if case .tab(let id, .cancel(let lane, let generation)) = effect,
           let active = running[id]?[lane], active.generation == generation {
            running[id]?[lane] = nil; active.cancellation.cancel()
        }
        if case .tab(let id, .cancel(.monitor, let generation)) = effect,
           let reload = monitorReloads[id], reload.generation == generation {
            monitorReloads[id] = nil; reload.cancellation.cancel()
        }
        if case .tab(let id, .refreshPaths) = effect {
            let previous = monitorReloads.removeValue(forKey: id)
            previous?.cancellation.cancel()
        }
        let slot = effectSlot(effect)
        if let (id, lane, _) = slot {
            let previous = running[id]?[lane]
            running[id]?[lane] = nil; previous?.cancellation.cancel()
        }
        let cancellation = runner.run(effect) { [weak self] action in self?.enqueue(action) }
        if case .tab(let id, .refreshPaths(_, let generation)) = effect, let cancellation {
            monitorReloads[id] = Running(generation: generation, cancellation: cancellation)
        }
        if let (id, lane, generation) = slot, let cancellation = cancellation {
            running[id, default: [:]][lane] = Running(generation: generation, cancellation: cancellation)
        }
    }

    private func effectSlot(_ effect: StoreEffect) -> (TabID, GenerationLane, Generation)? {
        guard case .tab(let id, let effect) = effect else { return nil }
        switch effect {
        case .load(_, let generation, _): return (id, .load, generation)
        case .startMonitor(_, let generation): return (id, .monitor, generation)
        case .startSearch(_, let generation): return (id, .search, generation)
        case .addressEditor(.requestCompletions(let request)): return (id, .completion, request.generation)
        default: return nil
        }
    }

    private func cancelTab(_ id: TabID) {
        monitorReloads.removeValue(forKey: id)?.cancellation.cancel()
        let handles = running.removeValue(forKey: id) ?? [:]
        // Fixed order avoids dictionary iteration influencing callback admission order.
        for lane in [GenerationLane.load, .monitor, .search, .completion] { handles[lane]?.cancellation.cancel() }
    }
    private func cancelAll() {
        for id in state.window.tabs { cancelTab(id) }
    }
}
