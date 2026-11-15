import Foundation
import HelmCore

/// What AI mode remembers between launches, shared by every window, Settings › AI and the AI mode screen, in ai.json:
/// the provider, the model for each provider, local ports and a typed address. Never a key, which is only ever in
/// the keychain. Without a file it lives in memory only (tests, and a file that couldn't be read).
@MainActor public final class AIConfigStore: AppFlushable {
    private let file: JSONFileStore<AIConfig>?
    private var memory = AIConfig()
    public var config: AIConfig { file?.items ?? memory }
    /// Sent after every real change, never for one that changes nothing.
    public let changes = Broadcast<AIConfig>()

    public init() { file = nil }
    public init(url: URL) async throws {
        let file = JSONFileStore<AIConfig>(url: url, empty: AIConfig())
        try await file.load()
        self.file = file
    }

    public func update(_ change: (inout AIConfig) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        if let file { file.replace(with: next) } else { memory = next }
        changes.send(next)
    }

    public func flush() async throws { try await file?.flush() }
}
