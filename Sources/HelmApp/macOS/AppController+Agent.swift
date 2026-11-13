#if os(macOS)
import AppKit
import HelmAgent
import HelmCore
import HelmFileSystem
import HelmUI

/// AI mode's services for the whole app, and how its settings reach them.
extension AppController {
    /// Every conversation is the real one, `AgentLiveParts.makeSession`: its folders, tools, plan checks and Apply
    /// are what a person gets. What lies outside the app is chosen by the run:
    /// - A fixture run keeps keys in memory, answers from the scripted model (the fixture's `agent-script.json` when
    ///   there is one), reads the fixture home through the real agent disk with stand-in place facts and marks on
    ///   top, and its connector opens nothing. No live model client can be built.
    /// - `--live-agent` is the same, but with no scripted model, so no model is ever ready.
    /// - Any other launch keeps keys in memory and an empty disk, and hands a server address to macOS as it always
    ///   has.
    func makeAgentServices(_ environment: AppEnvironment) -> AgentServices {
        let home = environment.directories.home
        let secrets = MemorySecretStore()
        let disk: any AgentDisk
        let storage: MemoryStorageFactsReader
        if options.isIsolated {
            // The smoke verbs name folders by their canonical paths, so the place rules are given the same spelling.
            let canonicalHome = CanonicalPath.realPath(home.path) ?? home.path
            storage = MemoryStorageFactsReader(home: URL(fileURLWithPath: canonicalHome, isDirectory: true))
            let base = FileSystemAgentDisk(fileSystem: environment.fileSystem, storage: storage, home: canonicalHome)
            disk = InjectedAgentDisk(base: base, allowedPrefix: canonicalHome)
        } else {
            storage = MemoryStorageFactsReader(home: home)
            disk = MemoryAgentDisk(home: home.path)
        }
        // The home as the windows spell a folder's path (standardized, so /private/tmp reads /tmp). The folder rules
        // also hold the home's canonical path, so a folder spelled either way is found inside it.
        let parts = AgentRuntimeParts(secrets: secrets, disk: disk, home: home.standardizedFileURL.path,
                                      supportFolder: environment.directories.applicationSupport.path,
                                      clock: environment.clock, buildStamp: Self.buildStamp(),
                                      scripted: options.usesLiveAgent ? nil : scriptedModel(home: home),
                                      makeSession: AgentLiveParts.makeSession)
        let connector: any ServerConnecting = options.isIsolated ? MemoryServerConnector() : SystemServerConnector()
        return AgentServices(runtime: AgentRuntime(parts: parts), config: environment.aiConfig, secrets: secrets, disk: disk,
                             storage: storage, connector: connector)
    }

    /// The scripted model. A fixture run takes its answers from `agent-script.json` beside the fixture home when that
    /// file is there and reads as a script; otherwise, and in any other run, it keeps the built-in answers.
    private func scriptedModel(home: URL) -> ScriptedModelClient {
        let scripted = ScriptedModelClient()
        guard options.isIsolated else { return scripted }
        let file = home.deletingLastPathComponent().appendingPathComponent(Self.fixtureScriptName).path
        if let text = try? String(contentsOfFile: file, encoding: .utf8) { try? scripted.load(Data(text.utf8)) }
        return scripted
    }

    /// The scripted model's answers for a fixture run, beside the fixture home (`smoke.d/agent.fixture.sh` writes it).
    static let fixtureScriptName = "agent-script.json"

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
