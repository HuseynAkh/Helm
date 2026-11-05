// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-051 adapter must compare and write in one synchronous MainActor turn (B-036/B-037).
@MainActor public protocol FilePasteboard {
    var changeCount: Int { get }
    func fileURLs() -> [URL]
    /// Returns the post-write counter, or nil if another application changed the clipboard.
    func replaceFileURLs(_ urls: [URL], ifChangeCount: Int) -> Int?
}
/// Pure copy/cut metadata; failed cut sources survive acknowledgment (F-051/B-037).
public struct ClipboardTransaction: Sendable, Equatable {
    public enum Mode: String, Sendable { case copy, cut }
    public let mode: Mode
    public let sources: [URL]
    public let changeCount: Int
    public init(mode: Mode, sources: [URL], changeCount: Int) {
        self.mode = mode; self.sources = sources.filter(\.isFileURL); self.changeCount = changeCount
    }
    public func isValid(currentChangeCount: Int) -> Bool { changeCount == currentChangeCount }
    /// Nil means stale metadata; an empty transaction means all cut sources completed.
    public func acknowledging(_ completedSources: Set<URL>, currentChangeCount: Int) -> ClipboardTransaction? {
        guard isValid(currentChangeCount: currentChangeCount) else { return nil }
        return ClipboardTransaction(mode: mode, sources: mode == .cut ? sources.filter { !completedSources.contains($0) } : sources,
                                    changeCount: changeCount)
    }
    /// The adapter is the only writer. External clipboard changes are never overwritten.
    @MainActor public func acknowledge(_ completedSources: Set<URL>, on pasteboard: any FilePasteboard) -> ClipboardTransaction? {
        guard let remaining = acknowledging(completedSources, currentChangeCount: pasteboard.changeCount) else { return nil }
        guard mode == .cut, remaining.sources != sources else { return remaining }
        guard let counter = pasteboard.replaceFileURLs(remaining.sources, ifChangeCount: changeCount) else { return nil }
        return ClipboardTransaction(mode: mode, sources: remaining.sources, changeCount: counter)
    }
}
