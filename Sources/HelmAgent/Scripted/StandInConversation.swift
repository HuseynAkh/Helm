import Foundation
import HelmCore

/// A conversation with no model behind it, for tests of what sits on top of one. Every message gets the same
/// reply and, when it was given one, the same plan. Folders are taken as they are typed, with nothing looked up on
/// a disk, and it keeps what it was sent and how each plan ended.
/// All reads and writes hold the lock.
public final class StandInConversation: AgentConversing, @unchecked Sendable {
    private let lock = NSLock()
    private var plan: AgentChangePlan?
    private let reply: String
    private var tabRoot: AgentScopeRoot?
    private var addedRoots: [AgentScopeRoot] = []
    private var aliasCount = 0
    private var usedPlans: Set<UUID> = []
    private var messages: [AgentPersonInput] = []
    private var settled: [AgentPlanOutcome] = []
    private var answers: [String: AgentFolderRef] = [:]
    private var ticket: AgentApplyTicket?
    private let noticeFeed: AsyncStream<AgentNotice>.Continuation

    /// `plan` is what every message is answered with, after `reply` when that isn't empty.
    public init(plan: AgentChangePlan? = nil, reply: String = "") {
        self.plan = plan
        self.reply = reply
        let (stream, feed) = AsyncStream.makeStream(of: AgentNotice.self)
        notices = stream
        noticeFeed = feed
    }

    /// Every message that was sent, in order.
    public var sent: [AgentPersonInput] { locked { messages } }
    /// How each plan ended, in the order it was told.
    public var outcomes: [AgentPlanOutcome] { locked { settled } }

    /// What to answer for a folder, by the text that names it. Text with no answer here is added as a new root.
    public var folderAnswers: [String: AgentFolderRef] {
        get { locked { answers } }
        set { locked { answers = newValue } }
    }

    /// What the next request to apply answers, once. Nil gives the usual answer: `.go` with the plan the first
    /// time its id and ticks are right, and `.refused` after that.
    public var nextTicket: AgentApplyTicket? {
        get { locked { ticket } }
        set { locked { ticket = newValue } }
    }

    // MARK: AgentConversing

    public let notices: AsyncStream<AgentNotice>

    public func roots() async -> [AgentScopeRoot] {
        locked { (tabRoot.map { [$0] } ?? []) + addedRoots }
    }

    public func setTabFolder(_ input: AgentRootInput?) async -> AgentTabFolder {
        locked {
            guard let input else {
                tabRoot = nil
                return .none
            }
            if case .refused(let refusal)? = answers[input.text] {
                tabRoot = nil
                return .refused(refusal)
            }
            if let tabRoot, tabRoot.path == input.text { return .root(tabRoot) }
            let root = makeRoot(path: input.text, isTabFolder: true)
            tabRoot = root
            return .root(root)
        }
    }

    public func folder(for input: AgentRootInput) async -> AgentFolderRef {
        locked {
            if let answer = answers[input.text] {
                if case .added(let root) = answer, !addedRoots.contains(where: { $0.alias == root.alias }) { addedRoots.append(root) }
                return answer
            }
            if let root = ((tabRoot.map { [$0] } ?? []) + addedRoots).first(where: { $0.path == input.text }) { return .root(root) }
            guard addedRoots.count + (tabRoot == nil ? 0 : 1) < AgentLimits.roots else { return .refused(.full) }
            let root = makeRoot(path: input.text, isTabFolder: false)
            addedRoots.append(root)
            return .added(root)
        }
    }

    public func removeRoot(alias: String) async {
        locked { addedRoots.removeAll { $0.alias == alias } }
        noticeFeed.yield(.startedOver)
    }

    public func send(_ input: AgentPersonInput) -> AsyncStream<AgentSessionEvent> {
        let plan = locked { () -> AgentChangePlan? in
            messages.append(input)
            return self.plan
        }
        var events: [AgentSessionEvent] = [.status(.thinking)]
        if !reply.isEmpty { events.append(.reply(reply)) }
        if let plan { events.append(.plan(plan)) }
        events.append(.finished)
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    public func beginApply(planID: UUID, ticked: Set<Int>) async -> AgentApplyTicket {
        locked {
            if let answer = ticket {
                ticket = nil
                // A changed plan takes the old one's place, as it does in a real conversation.
                if case .changed(let next) = answer { plan = next }
                if case .go(let gone) = answer { usedPlans.insert(gone.id) }
                return answer
            }
            guard let plan, plan.id == planID, !usedPlans.contains(planID), plan.isTickSet(ticked) else { return .refused }
            usedPlans.insert(planID)
            return .go(plan)
        }
    }

    public func settle(planID: UUID, _ outcome: AgentPlanOutcome) async {
        locked { settled.append(outcome) }
    }

    public func stop() async {}

    public func startOver() async {
        noticeFeed.yield(.startedOver)
    }

    public func clear() async {
        locked { addedRoots.removeAll() }
        noticeFeed.yield(.startedOver)
    }

    // MARK: Roots

    /// A root for text taken as a path. The alias comes from a count that never goes back, so one is never used twice.
    private func makeRoot(path: String, isTabFolder: Bool) -> AgentScopeRoot {
        aliasCount += 1
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return AgentScopeRoot(alias: "r\(aliasCount)", path: path, label: name, modelName: name, identity: nil,
                              storage: .thisMac, isTabFolder: isTabFolder)
    }

    @discardableResult private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
