// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Completion request owns its generation so programmatic edits cannot orphan it (F-016, F-017).
public struct CompletionRequest: Hashable, Sendable {
    public let parent: URL
    public let prefix: String
    public let isSlashBrowsing: Bool
    public let showHidden: Bool
    public let generation: Generation
    public init(parent: URL, prefix: String, isSlashBrowsing: Bool, showHidden: Bool, generation: Generation) {
        self.parent = parent; self.prefix = prefix; self.isSlashBrowsing = isSlashBrowsing
        self.showHidden = showHidden; self.generation = generation
    }
}
