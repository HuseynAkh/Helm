import Foundation
import HelmCore

/// Versioned window/tab restoration retains the frame autosave names (F-068).
@MainActor public final class SessionStore {
    private let file: JSONFileStore<[SessionWindow]>
    public var windows: [SessionWindow] { file.items }
    public let changes: Broadcast<[SessionWindow]>
    public var lastError: (any Error)? { file.lastError }
    public init(url: URL) async throws {
        file = JSONFileStore(url: url, empty: [])
        changes = file.changes
        try await file.load()
    }
    public func replace(windows: [SessionWindow]) { file.replace(with: windows) }
    /// Forgets the windows and deletes session.json, as when Reopen windows and tabs is off.
    public func remove() { file.remove() }
    public func flush() async throws { try await file.flush() }
}
