#if os(macOS)
import AppKit
import HelmAgent
import HelmCore
import HelmFileSystem
import HelmUI

/// AI mode's services for the whole app, and how its settings reach them.
extension AppController {
    /// Every run gets stand-ins for what lies outside the app: keys kept in memory, an empty disk, every folder on this
    /// Mac and no live model client. A fixture run's connector opens nothing; a real launch hands a server address
    /// to macOS as it always has. `--live-agent` leaves out the scripted model as well, so no model is ever ready.
    func makeAgentServices(_ environment: AppEnvironment) -> AgentServices {
        let home = environment.directories.home
        let secrets = MemorySecretStore()
        let disk = MemoryAgentDisk(home: home.path)
        let parts = AgentRuntimeParts(secrets: secrets, disk: disk, home: home.path,
                                      supportFolder: environment.directories.applicationSupport.path,
                                      clock: environment.clock, buildStamp: Self.buildStamp(),
                                      scripted: options.usesLiveAgent ? nil : ScriptedModelClient())
        let connector: any ServerConnecting = options.isIsolated ? MemoryServerConnector() : SystemServerConnector()
        return AgentServices(runtime: AgentRuntime(parts: parts), config: environment.aiConfig, secrets: secrets, disk: disk,
                             storage: MemoryStorageFactsReader(home: home), connector: connector)
    }

    /// Settings › AI's switch and the choices saved in ai.json reach the runtime as they change, starting now.
    func followAIMode() {
        guard let environment, let agent = dependencies?.agent else { return }
        let runtime = agent.runtime
        runtime.configure(agent.config.config)
        runtime.setOn(environment.settings.snapshot.bool(.aiModeEnabled))
        _ = environment.settings.changes.subscribe { settings in runtime.setOn(settings.bool(.aiModeEnabled)) }
        _ = agent.config.changes.subscribe { config in runtime.configure(config) }
    }

    /// Which build is running, as the executable's size and modification date. A key saved by another build may need
    /// macOS's permission again. It names no path.
    static func buildStamp() -> String {
        guard let executable = Bundle.main.executableURL,
              let values = try? executable.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return "" }
        let size = values.fileSize.map(String.init) ?? "?"
        let modified = values.contentModificationDate.map { String(Int($0.timeIntervalSince1970)) } ?? "?"
        return "\(size)-\(modified)"
    }

    public var agentServicesForTesting: AgentServices? { dependencies?.agent }
}
#endif
