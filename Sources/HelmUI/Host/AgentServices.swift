#if os(macOS)
import Foundation
import HelmAgent
import HelmCore
import HelmFileSystem
import HelmPersistence

/// What AI mode needs from the app, shared by every window, Settings › AI and the AI mode screen: the runtime that
/// owns the model client, the saved choices, the key store, the read-only disk, the facts about where a folder is,
/// the way a server address reaches macOS, and the way a page reaches the person's browser.
@MainActor public struct AgentServices {
    public let runtime: AgentRuntime
    public let config: AIConfigStore
    public let secrets: any AgentSecretStoring
    public let disk: any AgentDisk
    public let storage: any StorageFactsReading
    public let connector: any ServerConnecting
    /// Reads inside files on this Mac for Read contents, with the person's permit. Nil in a run that reads nothing.
    public let contents: (any AgentContentReading)?
    /// Hands an address to the person's default browser, and says whether it went: a help page, ChatGPT's usage page,
    /// or the ChatGPT sign-in. Helm makes no connection itself. The stand-in opens nothing, so a fixture run never
    /// takes the screen.
    public let openInBrowser: @MainActor @Sendable (URL) -> Bool

    public init(runtime: AgentRuntime, config: AIConfigStore, secrets: any AgentSecretStoring, disk: any AgentDisk,
                storage: any StorageFactsReading, connector: any ServerConnecting,
                openInBrowser: @escaping @MainActor @Sendable (URL) -> Bool = { _ in false },
                contents: (any AgentContentReading)? = nil) {
        self.runtime = runtime; self.config = config; self.secrets = secrets; self.disk = disk
        self.storage = storage; self.connector = connector; self.openInBrowser = openInBrowser; self.contents = contents
        // Each check's list of models is kept in ai.json under the provider and where it was asked, for the panel's
        // model menu; a check that fails takes that list away.
        runtime.checked = { [config] profile, models in
            config.update { saved in
                let names = models?.map(\.id) ?? []
                saved.modelLists[profile.secretID.account] = names.isEmpty ? nil : names
                // And which of them can't see pictures, where the provider says.
                let textOnly = models?.filter { $0.seesPictures == false }.map(\.id) ?? []
                saved.textOnlyModels[profile.secretID.account] = textOnly.isEmpty ? nil : textOnly
            }
        }
    }

    /// Nothing outside the app: a scripted model, keys and choices in memory, an empty disk, every folder on this
    /// Mac, and a connector that opens nothing. AI mode starts off. Tests and windows built without the app use it.
    public static func standIn(home: URL, clock: any HelmClock) -> AgentServices {
        let secrets = MemorySecretStore()
        let disk = MemoryAgentDisk(home: home.path)
        let parts = AgentRuntimeParts(secrets: secrets, disk: disk, home: home.path,
                                      supportFolder: home.appendingPathComponent(".helm-support", isDirectory: true).path,
                                      clock: clock, buildStamp: "", scripted: ScriptedModelClient())
        return AgentServices(runtime: AgentRuntime(parts: parts), config: AIConfigStore(), secrets: secrets, disk: disk,
                             storage: MemoryStorageFactsReader(home: home), connector: MemoryServerConnector())
    }
}
#endif
