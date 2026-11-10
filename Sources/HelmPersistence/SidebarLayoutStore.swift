import Foundation
import HelmCore

/// The sidebar's order and hidden rows, shared by every window and Settings › Sidebar, in sidebar.json.
/// It's a document of its own rather than a setting: a settings change resets every tab, while a sidebar
/// change only redraws sidebars. Without a file it lives in memory only (tests, and a file that couldn't be read).
@MainActor public final class SidebarLayoutStore: AppFlushable {
    private let file: JSONFileStore<SidebarLayout>?
    private var memory = SidebarLayout()
    public var layout: SidebarLayout { file?.items ?? memory }
    /// Sent after every real change, never for one that changes nothing.
    public let changes = Broadcast<SidebarLayout>()

    public init() { file = nil }
    public init(url: URL) async throws {
        let file = JSONFileStore<SidebarLayout>(url: url, empty: SidebarLayout())
        try await file.load()
        self.file = file
    }

    public func update(_ change: (inout SidebarLayout) -> Void) {
        var next = layout
        change(&next)
        guard next != layout else { return }
        if let file { file.replace(with: next) } else { memory = next }
        changes.send(next)
    }

    /// Every row shown, in its natural order. Bookmarks keep the order they have in bookmarks.json.
    public func restoreDefaults() { update { $0 = SidebarLayout() } }

    public func flush() async throws { try await file?.flush() }
}
