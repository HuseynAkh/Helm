#if os(macOS)
import Foundation
import HelmAgent
import HelmCore
import HelmFileSystem
import HelmOperations

/// What applying a plan did: how many changes were done and skipped out of how many, whether it stopped before the
/// end, the names the Trash refused, the items it changed, and the history group its changes were recorded under.
public struct AgentApplyReport: Equatable, Sendable {
    public let done: Int, skipped: Int, total: Int
    public let stoppedEarly: Bool
    public let trashFailed: [String]
    public let changed: [URL]
    public let group: HistoryGroup?
    public init(done: Int, skipped: Int, total: Int, stoppedEarly: Bool, trashFailed: [String], changed: [URL], group: HistoryGroup?) {
        self.done = done; self.skipped = skipped; self.total = total; self.stoppedEarly = stoppedEarly
        self.trashFailed = trashFailed; self.changed = changed; self.group = group
    }
}

/// Runs the ticked part of an approved plan through the window's own file commands, one command at a time, inside
/// the window's turn. Every command is recorded under one history group named after the plan, so one Undo takes it
/// all back. A name that is taken keeps both, an item that fails is skipped, and nothing is fetched from a cloud.
/// Right before each command every item it moves, copies, renames or trashes is read again, and an item that is no
/// longer the one on the card is left alone.
@MainActor struct AgentPlanApplier {
    private weak var window: BrowserWindowController?

    init(window: BrowserWindowController) { self.window = window }

    /// `progress` gets the changes handled so far, the changes in all, and the name of the item in hand. `shouldStop`
    /// is asked before each command: once it says yes, nothing more runs and the report says it stopped early.
    /// `pauseBetween` holds each command after the first back that long; scripted runs use it to press Stop midway.
    func apply(_ plan: AgentChangePlan, ticked: Set<Int>, shouldStop: @escaping @MainActor () -> Bool = { false },
               pauseBetween: TimeInterval = 0, progress: @escaping (Int, Int, String) -> Void) async -> AgentApplyReport {
        let commands = AgentPlanCompiler.commands(for: plan, ticked: ticked)
        let total = commands.reduce(0) { $0 + Self.size(of: $1) }
        let group = HistoryGroup(name: plan.title.text)
        var tally = Tally()
        var made: [String: URL] = [:]

        for (index, command) in commands.enumerated() {
            if index > 0, pauseBetween > 0 { try? await Task.sleep(nanoseconds: UInt64(pauseBetween * 1_000_000_000)) }
            if shouldStop() { tally.stopped = true }
            guard !tally.stopped else { break }
            guard let window else { tally.stopped = true; break }
            let fileSystem = window.dependencies.fileSystem
            switch command {
            case .createFolder(let key, let parent, let name):
                progress(tally.handled, total, name.value)
                guard let folder = Self.address(of: parent, made: made) else { tally.skipped += 1; continue }
                let outcome = await Self.run(.createFolder(parent: folder, name: name), group: group, in: window)
                let result = tally.count(outcome, items: 1)
                if let created = result?.outcomes.first(where: { $0.succeeded && $0.step.kind == .createDirectory })?.destination {
                    made[key] = created
                    tally.changed.append(created)
                }
            case .createFile(let parent, let name, let contents):
                progress(tally.handled, total, name.value)
                // Written once, never over another file, and without the executable bit.
                guard let folder = Self.address(of: parent, made: made), let contents else { tally.skipped += 1; continue }
                let outcome = await Self.run(.createFile(parent: folder, name: name, template: nil, contents: contents),
                                             group: group, in: window)
                tally.collect(tally.count(outcome, items: 1))
            case .batchRename(let renames):
                progress(tally.handled, total, renames.first?.source.url.lastPathComponent ?? "")
                let still = await Self.unchanged(renames.map(\.source), in: fileSystem)
                let pairs = renames.filter { still.contains($0.source.url) }.map { RenamePair(source: $0.source.url, newName: $0.name) }
                tally.skipped += renames.count - pairs.count
                guard !pairs.isEmpty else { continue }
                let outcome = await Self.run(.batchRename(pairs), group: group, in: window)
                tally.collect(tally.count(outcome, items: pairs.count))
            case .move(let sources, let parent), .copy(let sources, let parent):
                progress(tally.handled, total, sources.first?.url.lastPathComponent ?? "")
                guard let destination = Self.address(of: parent, made: made) else {
                    // The folder it was going into couldn't be made, so nothing goes anywhere else instead.
                    tally.skipped += sources.count
                    continue
                }
                let still = await Self.unchanged(sources, in: fileSystem)
                let urls = sources.map(\.url).filter(still.contains)
                tally.skipped += sources.count - urls.count
                guard !urls.isEmpty else { continue }
                let isMove: Bool
                if case .move = command { isMove = true } else { isMove = false }
                let fileCommand: Command = isMove ? .move(sources: urls, destinationDirectory: destination)
                                                  : .copy(sources: urls, destinationDirectory: destination)
                let outcome = await Self.run(fileCommand, group: group, in: window)
                tally.collect(tally.count(outcome, items: urls.count))
            case .trash(let sources):
                progress(tally.handled, total, sources.first?.url.lastPathComponent ?? "")
                let still = await Self.unchanged(sources, in: fileSystem)
                let urls = sources.map(\.url).filter(still.contains)
                tally.skipped += sources.count - urls.count
                guard !urls.isEmpty else { continue }
                let outcome = await Self.run(.trash(items: urls), group: group, in: window)
                let result = tally.count(outcome, items: urls.count)
                if let result {
                    tally.trashFailed += result.outcomes.filter { $0.step.kind == .trash && !$0.succeeded }
                        .compactMap { $0.step.source?.lastPathComponent }
                } else if case .failure(.message) = outcome {
                    tally.trashFailed += urls.map(\.lastPathComponent)
                }
            }
        }
        let unreached = max(0, total - tally.done - tally.skipped)
        return AgentApplyReport(done: tally.done, skipped: tally.skipped + (tally.stopped ? 0 : unreached), total: total,
                                stoppedEarly: tally.stopped, trashFailed: tally.trashFailed, changed: tally.changed,
                                group: tally.done > 0 ? group : nil)
    }

    /// What has happened so far.
    private struct Tally {
        var done = 0, skipped = 0
        var stopped = false
        var trashFailed: [String] = []
        var changed: [URL] = []
        var handled: Int { done + skipped }

        /// Counts what a command did with `items` items, and stops the rest when it was turned away or left the disk
        /// unsure. Hands back the result when the command ran.
        mutating func count(_ outcome: Result<OperationResult, OperationCoordinator.Failure>, items: Int) -> OperationResult? {
            switch outcome {
            case .failure(.busy):
                stopped = true
                return nil
            case .failure(.cancelled), .failure(.message):
                // Nothing was left to do, or the command couldn't be planned: nothing happened to these items.
                skipped += items
                return nil
            case .success(let result):
                let succeeded = min(items, result.succeededItemCount)
                done += succeeded
                skipped += items - succeeded
                if result.error == .timedOut || result.error == .busy || result.outcomes.contains(where: \.requiresReconciliation) {
                    stopped = true
                }
                return result
            }
        }

        /// Keeps where each changed item is now.
        mutating func collect(_ result: OperationResult?) {
            guard let result else { return }
            changed += result.outcomes.filter { $0.succeeded && $0.step.kind != .trash && $0.step.kind != .verifyCopy }
                .compactMap(\.destination)
        }
    }

    /// How many changes a command stands for.
    private static func size(of command: AgentCompiledCommand) -> Int {
        switch command {
        case .createFolder, .createFile: return 1
        case .batchRename(let renames): return renames.count
        case .move(let sources, _), .copy(let sources, _), .trash(let sources): return sources.count
        }
    }

    private static func address(of parent: AgentCompiledParent, made: [String: URL]) -> URL? {
        switch parent {
        case .url(let url): return url
        case .key(let key): return made[key]
        }
    }

    private static func run(_ command: Command, group: HistoryGroup, in window: BrowserWindowController) async
        -> Result<OperationResult, OperationCoordinator.Failure> {
        // A name that is taken keeps both, every time, with nothing asked.
        let keepBoth: OperationCoordinator.ConflictResolver = { _ in ConflictPolicy(defaultResolution: .keepBoth, applyToAll: true) }
        let skip: OperationCoordinator.FailureResolver = { _ in .skip }
        return await window.runAwaiting(command, group: group, resolver: keepBoth, onFailure: skip, downloadsOff: true)
    }

    /// The items that are still the ones the plan was checked against: the same identity, where the plan knew it, and
    /// the same kind. Read with downloads off, so asking about an item never fetches it.
    private static func unchanged(_ sources: [AgentCompiledSource], in fileSystem: any FileSystem) async -> Set<URL> {
        await DatalessGuard.off {
            var kept: Set<URL> = []
            for source in sources {
                do {
                    let now = try await fileSystem.mutationPrecondition(at: source.url)
                    if now.kind == source.kind, source.identity == nil || now.identity == source.identity { kept.insert(source.url) }
                } catch ConditionalMutationError.unsupported {
                    // A file system that can't tell identities apart is asked for the kind alone.
                    if let entry = try? await fileSystem.entry(at: source.url), entry.kind == source.kind { kept.insert(source.url) }
                } catch {
                    continue
                }
            }
            return kept
        }
    }
}
#endif
