#if os(macOS)
import Foundation
import HelmCore

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
#endif
