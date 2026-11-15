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
    /// - `--live-agent` is the same, but with no scripted model: the client is the one a real launch builds, so a
    ///   request goes to the transport that ships, which the smoke run's sandbox then stops.
    /// - Any other launch keeps keys in the login keychain, reads the home folder through the real agent disk with
    ///   macOS's own place facts, and hands a server address to macOS. It alone can sign in with ChatGPT, and it alone
    ///   hands a help page or the sign-in to the default browser; a fixture run opens nothing.
    /// In every run the client is built only while AI mode is on, the first time a request needs it.
    func makeAgentServices(_ environment: AppEnvironment) -> AgentServices {
        let home = environment.directories.home
        // The folder rules and the place facts work on the canonical home, as the disk spells every folder in it.
        let canonicalHome = CanonicalPath.realPath(home.path) ?? home.path
        let canonicalURL = URL(fileURLWithPath: canonicalHome, isDirectory: true)
        let secrets: any AgentSecretStoring
        let disk: any AgentDisk
        let storage: any StorageFactsReading
        let connector: any ServerConnecting
        if options.isIsolated {
            let facts = MemoryStorageFactsReader(home: canonicalURL)
            let base = FileSystemAgentDisk(fileSystem: environment.fileSystem, storage: facts, home: canonicalHome)
            secrets = MemorySecretStore()
            storage = facts
            disk = InjectedAgentDisk(base: base, allowedPrefix: canonicalHome)
            connector = MemoryServerConnector()
        } else {
            let facts = SystemStorageFactsReader(home: canonicalURL)
            secrets = KeychainSecretStore()
            storage = facts
            disk = FileSystemAgentDisk(fileSystem: environment.fileSystem, storage: facts, home: canonicalHome)
            connector = SystemServerConnector()
        }
        let scripted = options.isIsolated && !options.usesLiveAgent ? scriptedModel(home: home) : nil
        // The home as the windows spell a folder's path (standardized, so /private/tmp reads /tmp). The folder rules
        // also hold the home's canonical path, so a folder spelled either way is found inside it.
        let parts = AgentRuntimeParts(secrets: secrets, disk: disk, home: home.standardizedFileURL.path,
                                      supportFolder: environment.directories.applicationSupport.path,
                                      clock: environment.clock, buildStamp: Self.buildStamp(), scripted: scripted,
                                      makeClient: scripted == nil ? AgentLiveParts.makeClient : nil,
                                      makeSession: AgentLiveParts.makeSession,
                                      makeSignIn: options.isIsolated ? nil : AgentLiveParts.makeSignIn)
        let isolated = options.isIsolated
        let openInBrowser: @MainActor @Sendable (URL) -> Bool = { @MainActor url in
            isolated ? false : NSWorkspace.shared.open(url)
        }
        return AgentServices(runtime: AgentRuntime(parts: parts), config: environment.aiConfig, secrets: secrets, disk: disk,
                             storage: storage, connector: connector, openInBrowser: openInBrowser)
    }

    /// The scripted model of a fixture run. It takes its answers from `agent-script.json` beside the fixture home when
    /// that file is there and reads as a script, and keeps the built-in answers otherwise.
    private func scriptedModel(home: URL) -> ScriptedModelClient {
        let scripted = ScriptedModelClient()
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

    /// Quitting lets go of the model client and its cached key, as turning AI mode off does, without changing the
    /// setting. A request still out ends with the process.
    public func applicationWillTerminate(_ notification: Notification) {
        dependencies?.agent.runtime.setOn(false)
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
