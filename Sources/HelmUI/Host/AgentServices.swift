#if os(macOS)
import Foundation
import HelmAgent
import HelmCore
import HelmFileSystem
import HelmPersistence

/// What AI mode needs from the app, shared by every window, Settings › AI and the AI mode screen: the runtime that
/// owns the model client, the saved choices, the key store, the read-only disk, the facts about where a folder is,
/// and the way a server address reaches macOS.
@MainActor public struct AgentServices {
    public let runtime: AgentRuntime
    public let config: AIConfigStore
    public let secrets: any AgentSecretStoring
    public let disk: any AgentDisk
    public let storage: any StorageFactsReading
    public let connector: any ServerConnecting

    public init(runtime: AgentRuntime, config: AIConfigStore, secrets: any AgentSecretStoring, disk: any AgentDisk,
                storage: any StorageFactsReading, connector: any ServerConnecting) {
        self.runtime = runtime; self.config = config; self.secrets = secrets; self.disk = disk
        self.storage = storage; self.connector = connector
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
