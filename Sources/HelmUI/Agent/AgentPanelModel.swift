#if os(macOS)
import Foundation
import HelmCore

/// What the AI panel shows and what its controls do. It has no folder, thread or plan, so every reader answers empty
/// and every control does nothing.
@MainActor public final class AgentPanelModel: ObservableObject {
    public enum Phase: String, Sendable { case noFolder, idle, working, plan, applying, result, failed }
    @Published public private(set) var phase: Phase = .noFolder

    public init() {}

    public func type(_ text: String) {}
    public func send() {}
    public func press(_ title: String) {}
    public func tick(_ groupTitle: String) {}
    public func drop(_ folder: URL) {}
    public func chooseModel(_ id: String) {}
    /// "escape" or "return", as the composer would get it.
    public func key(_ name: String) {}

    /// The phase's name.
    public var phaseForTesting: String { phase.rawValue }
    /// The folders row, each as "label:kind", such as "Documents:thisMac".
    public var chipsForTesting: [String] { [] }
    /// Each chip's place line, by its label.
    public var chipKindsForTesting: [String: String] { [:] }
    public var suggestionsForTesting: [String] { [] }
    public var threadTextForTesting: String { "" }
    public var planCountsForTesting: String? { nil }
    /// Each group as "title:on" or "title:off", with its mark after another colon when it has one.
    public var groupsForTesting: [String] { [] }
    /// Whether a request, an Apply or an Undo is still running.
    public var isWaitingForTesting: Bool { false }
}
#endif
