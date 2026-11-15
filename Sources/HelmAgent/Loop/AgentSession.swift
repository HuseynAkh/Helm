import Foundation
import HelmCore

/// One window's conversation with a model: its folders, its thread, and the plan that waits for the person.
///
/// A request is a loop of model turns. Each turn's tool calls run in order through `AgentToolRunner`, and their
/// results go back together in one user turn. A turn that ends in a refusal, a content filter or the token ceiling
/// is dropped and none of its calls run. A plan ends the request: the session keeps it, and the turn's results are
/// held back until the person decides, so the model is never told something that didn't happen. The held results
/// are the first thing in the next request, with the plan's outcome, or "pending" while its card is still open.
///
/// A request that asks for changes, a suggestion's or a typed one that `AgentChangeAsk` reads as one, ends in a plan
/// when it can: when the model ends its turn with words and no plan, Helm sends `AgentPrompt.planNow` once, inside
/// the request's own turns and time, and the words wait. They are shown only if the next turn brings neither words
/// nor a plan.
///
/// Every limit of a request is Helm's: turns, calls, entries, plans, bad arguments and time. Text Helm builds, the
/// context note and each tool result, is checked for the home folder's path before it is sent; one that holds it
/// ends the request and is never sent. A thread starts over after 30 requests or 8 MB of history.
public actor AgentSession: AgentConversing {
    private let parts: AgentSessionParts
    private let validator: any AgentPlanValidating
    private let scope: AgentScope
    private let slot = RequestSlot()
    private let noticeFeed: AsyncStream<AgentNotice>.Continuation

    private var history: [AgentJSON] = []
    private var historyBytes = 0
    private var requests = 0
    /// The plan whose card is open. Only this plan's id can be applied, and only once.
    private var pending: AgentChangePlan?
    private var usedPlans: Set<UUID> = []
    /// The results of the turn that proposed the pending plan, not yet sent.
    private var held: HeldTurn?
    /// A plan whose result went out as pending: its outcome rides in the next context note.
    private var awaitingOutcome: UUID?
    private var outcomeForNote: AgentPlanOutcome?
    private var resultHook: (@Sendable (String) -> String)?

    public nonisolated let notices: AsyncStream<AgentNotice>

    public init(parts: AgentSessionParts, validator: any AgentPlanValidating) {
        self.parts = parts
        self.validator = validator
        self.scope = AgentScope(disk: parts.disk, home: parts.home, supportFolder: parts.supportFolder)
        let (stream, feed) = AsyncStream.makeStream(of: AgentNotice.self)
        notices = stream
        noticeFeed = feed
    }

    // MARK: Folders

    public func roots() async -> [AgentScopeRoot] { await scope.roots() }

    public func setTabFolder(_ input: AgentRootInput?) async -> AgentTabFolder { await scope.setTabFolder(input) }

    public func folder(for input: AgentRootInput) async -> AgentFolderRef { await scope.folder(for: input) }

    /// Removes an added folder and starts the thread over, so names listed in it are never sent again.
    public func removeRoot(alias: String) async {
        await stop()
        await scope.remove(alias: alias)
        resetThread()
        noticeFeed.yield(.startedOver)
    }

    // MARK: Requests

    /// Sends the person's message. While a request is open another is refused: its stream ends at once with
    /// nothing sent.
    public nonisolated func send(_ input: AgentPersonInput) -> AsyncStream<AgentSessionEvent> {
        let (stream, events) = AsyncStream.makeStream(of: AgentSessionEvent.self)
        guard slot.open(events) else {
            events.yield(.finished)
            events.finish()
            return stream
        }
        let task = Task { await self.perform(input, events: events) }
        slot.attach(task)
        return stream
    }

    public func stop() async {
        guard let open = slot.requestStop() else { return }
        open.events.yield(.status(.stopping))
        open.task?.cancel()
        await open.task?.value
    }

    public func startOver() async {
        await stop()
        await scope.startOver()
        resetThread()
        noticeFeed.yield(.startedOver)
    }

    public func clear() async {
        await stop()
        await scope.clear()
        resetThread()
        noticeFeed.yield(.startedOver)
    }

    // MARK: Plans

    /// The pending plan for these ticks, checked against the disk again. `.go` answers once for a plan; a plan
    /// that changed becomes the pending plan in its place, and the old id can't be applied.
    public func beginApply(planID: UUID, ticked: Set<Int>) async -> AgentApplyTicket {
        guard let plan = pending, plan.id == planID, !usedPlans.contains(planID), plan.isTickSet(ticked) else { return .refused }
        // Marked before the check, so a second ask made while the first waits is refused.
        usedPlans.insert(planID)
        let answer = await validator.recheck(plan, ticked: ticked, scope: scope, disk: parts.disk)
        guard pending?.id == planID else { return .refused }
        switch answer {
        case .ok:
            return .go(plan)
        case .changed(let next):
            pending = next
            if held?.planID == planID { held?.planID = next.id }
            if awaitingOutcome == planID { awaitingOutcome = next.id }
            return .changed(next)
        case .notResponding(let label):
            usedPlans.remove(planID)
            return .notResponding(label: label)
        case .disconnected(let label):
            usedPlans.remove(planID)
            return .disconnected(label: label)
        }
    }

    /// How the plan ended. While its turn's results are still held, the outcome goes into the result; otherwise it
    /// rides in the next context note.
    public func settle(planID: UUID, _ outcome: AgentPlanOutcome) async {
        if held?.planID == planID {
            held?.outcome = outcome
        } else if awaitingOutcome == planID {
            awaitingOutcome = nil
            outcomeForNote = outcome
        }
        if pending?.id == planID { pending = nil }
    }

    // MARK: Testing

    /// Changes each tool result before it is checked and sent, so a test can make one hold what it never should.
    func setToolResultHookForTesting(_ hook: (@Sendable (String) -> String)?) {
        resultHook = hook
    }

    // MARK: The loop

    private func perform(_ input: AgentPersonInput, events: AsyncStream<AgentSessionEvent>.Continuation) async {
        await request(input, emit: { events.yield($0) })
        slot.close()
        events.yield(.finished)
        events.finish()
    }

    private func request(_ input: AgentPersonInput, emit: (AgentSessionEvent) -> Void) async {
        if requests >= AgentLimits.threadRequests || historyBytes > AgentLimits.threadBytes {
            await scope.startOver()
            resetThread()
            emit(.notice(.startedOver))
        }
        let client: any AgentModelClient
        switch await parts.client() {
        case .failure(let failure):
            emit(.failed(failure))
            return
        case .success(let found):
            client = found
        }
        let limits: AgentLimits = client.isLocal ? .localModel : .cloudModel
        let listSeconds = parts.listSecondsOverride()
        await scope.beginRequest(listSeconds: listSeconds)
        for root in await scope.dropChangedRoots() { emit(.notice(.disconnected(label: root.label))) }
        if isStopping { return emit(.notice(.stopped)) }

        let roots = await scope.roots()
        let selectedRoot = Self.root(holding: input.selectedPaths, in: roots)
        let note = AgentContextNote.make(roots: roots, selectedCount: selectedRoot == nil ? 0 : input.selectedPaths.count,
                                         selectedRoot: selectedRoot, lastPlan: outcomeForNote,
                                         holdingCloudOnly: await scope.rootsHoldingCloudOnly())
        guard await isClean(note) else { return emit(.failed(.unreadable)) }
        outcomeForNote = nil
        let words = String(input.text.prefix(limits.messageCharacters))
        commit(client.userItems(text: note + "\n" + words, toolResults: takeHeldResults()))
        requests += 1

        let runner = AgentToolRunner(scope: scope, disk: parts.disk, validator: validator, limits: limits).usingListSeconds(listSeconds)
        let asksForChanges = input.asksForChanges || AgentChangeAsk.asksForChanges(input.text)
        let sent = await turns(client: client, runner: runner, limits: limits, selected: Set(input.selectedPaths),
                               asksForChanges: asksForChanges, emit: emit)
        if runner.notLoaded > 0 { emit(.notice(.foldersNotLoaded(runner.notLoaded))) }
        if sent > 0 { emit(.trace(.sent(names: sent, destination: client.destination))) }
    }

    /// The model turns of one request, until the model ends its turn, a plan arrives, or something ends the request.
    /// Answers how many names went into the thread: those of a turn that was dropped never leave the app.
    private func turns(client: any AgentModelClient, runner: AgentToolRunner, limits: AgentLimits, selected: Set<String>,
                       asksForChanges: Bool, emit: (AgentSessionEvent) -> Void) async -> Int {
        let started = parts.clock.now()
        var counts = RequestCounts()
        /// The words of the turn that ended without a plan, while the model is asked for one.
        var waitingReply: String?
        var askedForPlan = false
        func show(_ reply: String) {
            waitingReply = nil
            if !reply.isEmpty { emit(.reply(reply)) }
        }
        func ended(_ event: AgentSessionEvent) -> Int {
            if case .plan = event { waitingReply = nil }
            if let waiting = waitingReply { show(waiting) }
            emit(event)
            return counts.names
        }
        func secondsLeft() -> Double { limits.requestSeconds - parts.clock.now().timeIntervalSince(started) }
        let turnCount = max(0, limits.turns)
        for turn in 0..<turnCount {
            if secondsLeft() < 0 { return ended(.notice(.limitReached)) }
            emit(.status(.thinking))
            let streamed: StreamedTurn
            do {
                let input = AgentTurnInput(system: AgentPrompt.system, tools: AgentToolCatalog.all, history: history)
                streamed = try await Self.stream(client, input, replyCharacters: limits.replyCharacters, seconds: secondsLeft())
            } catch {
                if isStopping { return ended(.notice(.stopped)) }
                return ended(.failed(error as? AgentFailure ?? .unreadable))
            }
            if isStopping { return ended(.notice(.stopped)) }
            let text: String, finished: AgentTurnResult?
            switch streamed {
            case .outOfTime: return ended(.notice(.limitReached))
            case .done(let streamedText, let result): (text, finished) = (streamedText, result)
            }
            guard let result = finished else { return ended(.failed(.unreadable)) }
            switch result.stop {
            case .refusal, .contentFilter: return ended(.failed(.declined))
            case .maxTokens: return ended(.failed(.tooLarge))
            case .failed(let failure): return ended(.failed(failure))
            case .endTurn, .toolUse: break
            }
            guard Self.callIDsAreReadable(result.calls) else { return ended(.failed(.unreadable)) }
            let reply = AgentReplyText.clean(text, limit: limits.replyCharacters)
            if result.calls.isEmpty {
                commit(result.rawItems)
                // Words where a plan was asked for: ask once for the plan, while a turn and time are left.
                if asksForChanges, !askedForPlan, turn + 1 < turnCount, secondsLeft() > 0 {
                    askedForPlan = true
                    waitingReply = reply
                    commit(client.userItems(text: AgentPrompt.planNow, toolResults: []))
                    continue
                }
                show(reply.isEmpty ? waitingReply ?? "" : reply)
                return counts.names
            }
            if !reply.isEmpty { show(reply) }

            var results: [AgentToolResult] = []
            var plan: (plan: AgentChangePlan, index: Int)?
            var ending: AgentSessionEvent?
            var names = 0
            for (index, call) in result.calls.enumerated() {
                if plan != nil || ending != nil {
                    results.append(Self.errorResult(call, .limit_reached))
                    continue
                }
                if counts.calls >= limits.callsPerRequest {
                    results.append(Self.errorResult(call, .limit_reached))
                    ending = .notice(.limitReached)
                    continue
                }
                if index >= limits.callsPerTurn {
                    results.append(Self.errorResult(call, .limit_reached))
                    continue
                }
                // A turn that ran past the request's time runs none of its calls.
                if secondsLeft() < 0 {
                    results.append(Self.errorResult(call, .limit_reached))
                    ending = .notice(.limitReached)
                    continue
                }
                counts.calls += 1
                let isProposal = call.name == AgentToolRunner.proposeChangesName
                if isProposal {
                    counts.plans += 1
                    if counts.plans > limits.plansPerRequest {
                        results.append(Self.errorResult(call, .limit_reached))
                        ending = .notice(.limitReached)
                        continue
                    }
                    emit(.status(.checkingPlan))
                }
                let outcome = await runner.run(call, selectedPaths: selected)
                if isStopping { return ended(.notice(.stopped)) }
                switch outcome {
                case .plan(let proposed):
                    counts.badInARow = 0
                    plan = (proposed, results.count)
                    results.append(AgentToolResult(callID: call.id, name: call.name, json: Self.planStatus(nil, leftOut: [:])))
                case .error(let code):
                    results.append(Self.errorResult(call, code))
                    if code == .bad_arguments || code == .unknown_tool {
                        counts.badInARow += 1
                        if counts.badInARow >= limits.badArguments { ending = .failed(.noTools) }
                    } else {
                        counts.badInARow = 0
                    }
                    if code == .too_many {
                        counts.oversized += 1
                        if counts.oversized >= 2 { ending = .failed(.tooLarge) }
                    }
                    // A place the plan touches stopped answering: the request ends with one line and no retry.
                    if isProposal, code == .not_responding, ending == nil {
                        let label: String
                        if let slow = runner.slowRoot { label = slow } else { label = await quietRootLabel() }
                        ending = .notice(.notResponding(label: label))
                    }
                case .result(let json, let count):
                    counts.badInARow = 0
                    let sent = resultHook?(json) ?? json
                    // Nothing of this turn is kept, so the thread stays one the provider can read.
                    guard await isClean(sent) else { return ended(.failed(.unreadable)) }
                    results.append(AgentToolResult(callID: call.id, name: call.name, json: sent))
                    names += count
                    if !isProposal { emit(.status(.reading(count: runner.namesSent))) }
                }
                if ending == nil, let slow = runner.slowRoot { ending = .notice(.notResponding(label: slow)) }
            }

            counts.names += names
            if let plan {
                commit(result.rawItems)
                held = HeldTurn(results: results, planIndex: plan.index, planID: plan.plan.id, leftOut: plan.plan.leftOut)
                pending = plan.plan
                return ended(.plan(plan.plan))
            }
            commit(result.rawItems + client.userItems(text: nil, toolResults: results))
            if let ending { return ended(ending) }
        }
        return ended(.notice(.limitReached))
    }

    /// How a model turn's stream ended: with the text kept and the turn's result, or cut at the request's time.
    private enum StreamedTurn: Sendable {
        case done(String, AgentTurnResult?)
        case outOfTime
    }

    /// Streams one model turn, racing it against the seconds the request has left; the stream is cancelled when they
    /// run out. More text than can be shown is never kept.
    private static func stream(_ client: any AgentModelClient, _ input: AgentTurnInput, replyCharacters: Int,
                               seconds: Double) async throws -> StreamedTurn {
        try await withThrowingTaskGroup(of: StreamedTurn.self) { group in
            group.addTask {
                var text = ""
                var finished: AgentTurnResult?
                for try await event in client.turn(input) {
                    switch event {
                    case .text(let piece):
                        if text.count <= replyCharacters { text += piece }
                    case .toolStarted:
                        break
                    case .finished(let result):
                        finished = result
                    }
                }
                return .done(text, finished)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 86_400)) * 1_000_000_000))
                return .outOfTime
            }
            defer { group.cancelAll() }
            return try await group.next() ?? .outOfTime
        }
    }

    // MARK: The thread

    private func commit(_ items: [AgentJSON]) {
        history += items
        historyBytes += items.reduce(0) { $0 + $1.data().count }
    }

    /// The held results, with the plan's own result telling how it ended, or that its card is still open.
    private func takeHeldResults() -> [AgentToolResult] {
        guard let turn = held else { return [] }
        held = nil
        var results = turn.results
        guard results.indices.contains(turn.planIndex) else { return results }
        let call = results[turn.planIndex]
        if turn.outcome == nil { awaitingOutcome = turn.planID }
        results[turn.planIndex] = AgentToolResult(callID: call.callID, name: call.name,
                                                  json: Self.planStatus(turn.outcome, leftOut: turn.leftOut))
        return results
    }

    private func resetThread() {
        history = []
        historyBytes = 0
        requests = 0
        pending = nil
        held = nil
        awaitingOutcome = nil
        outcomeForNote = nil
    }

    private var isStopping: Bool { slot.isStopping || Task.isCancelled }

    /// The folder named when a plan's place stopped answering and no listing said which one: the folder on show,
    /// else the first folder.
    private func quietRootLabel() async -> String {
        let roots = await scope.roots()
        return (roots.first(where: \.isTabFolder) ?? roots.first)?.label ?? ""
    }

    /// Text Helm built never holds the home folder's path, as given or canonical.
    private func isClean(_ text: String) async -> Bool {
        let canonicalHome = await scope.canonicalHome()
        return AgentOutboundCheck.helmTextIsClean(text, home: parts.home) && AgentOutboundCheck.helmTextIsClean(text, home: canonicalHome)
    }

    // MARK: Parts

    private struct HeldTurn {
        var results: [AgentToolResult]
        var planIndex: Int
        var planID: UUID
        var leftOut: [AgentToolCode: Int]
        var outcome: AgentPlanOutcome?
    }

    private struct RequestCounts {
        var calls = 0, plans = 0, badInARow = 0, oversized = 0, names = 0
    }

    /// A plan's result: applied with its counts, dismissed, or pending while its card is open.
    static func planStatus(_ outcome: AgentPlanOutcome?, leftOut: [AgentToolCode: Int]) -> String {
        var members: [String: AgentJSON] = ["source": .string("plan")]
        switch outcome {
        case .applied(let done, let skipped)?:
            members["status"] = .string("applied")
            members["done"] = .number(Double(done))
            members["skipped"] = .number(Double(skipped))
            if leftOut.values.contains(where: { $0 > 0 }) { members["left_out"] = AgentToolRunner.leftOut(leftOut) }
        case .dismissed?:
            members["status"] = .string("dismissed")
        case nil:
            members["status"] = .string("pending")
        }
        return AgentToolRunner.text(.object(members))
    }

    static func errorResult(_ call: AgentToolCall, _ code: AgentToolCode) -> AgentToolResult {
        let json = AgentJSON.object(["source": .string("error"), "code": .string(code.rawValue)])
        return AgentToolResult(callID: call.id, name: call.name, json: AgentToolRunner.text(json), isError: true)
    }

    /// Every id present, at most 128 characters, and none twice.
    private static func callIDsAreReadable(_ calls: [AgentToolCall]) -> Bool {
        let ids = calls.map(\.id)
        return Set(ids).count == ids.count && ids.allSatisfy { !$0.isEmpty && $0.count <= AgentLimits.callIDCharacters }
    }

    /// The alias of the deepest root that holds the first selected item.
    private static func root(holding selected: [String], in roots: [AgentScopeRoot]) -> String? {
        guard let first = selected.first else { return nil }
        let item = AgentPathParts.comparable(first)
        return roots.filter { root in
            let parts = AgentPathParts.comparable(root.path)
            return item.count > parts.count && Array(item.prefix(parts.count)) == parts
        }.max { $0.path.count < $1.path.count }?.alias
    }

    /// The one request that may be open, its task and its events, behind a lock, so a second send is refused at
    /// once and Stop reaches the task however far it has got.
    private final class RequestSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var events: AsyncStream<AgentSessionEvent>.Continuation?
        private var task: Task<Void, Never>?
        private var stopping = false

        func open(_ events: AsyncStream<AgentSessionEvent>.Continuation) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard self.events == nil else { return false }
            self.events = events
            stopping = false
            return true
        }

        func attach(_ task: Task<Void, Never>) {
            lock.lock()
            defer { lock.unlock() }
            if events != nil { self.task = task }
        }

        func requestStop() -> (events: AsyncStream<AgentSessionEvent>.Continuation, task: Task<Void, Never>?)? {
            lock.lock()
            defer { lock.unlock() }
            guard let events else { return nil }
            stopping = true
            return (events, task)
        }

        var isStopping: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopping
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            events = nil
            task = nil
            stopping = false
        }
    }
}
