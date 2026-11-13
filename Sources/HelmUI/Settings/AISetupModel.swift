#if os(macOS)
import Foundation
import HelmAgent
import HelmCore
import HelmPersistence

/// What Settings › AI and the AI mode screen show and change: whether AI mode is on, the provider, its key and its
/// model. Both are drawn from one model, so they always agree.
@MainActor public final class AISetupModel: ObservableObject {
    /// Where the chosen provider stands, as the state line beside its key or local app says.
    public enum Connection: Equatable { case none, checking, connected(Int), noKey, wrongKey, cantReach, notRunning, noModels, keyDenied }

    private let settings: SettingsStore
    private let services: AgentServices

    @Published public private(set) var isOn: Bool
    /// The saved provider, else Claude.
    @Published public private(set) var provider: AgentProviderID
    @Published public private(set) var connection: Connection = .none
    @Published public private(set) var models: [AgentModelInfo] = []
    @Published public private(set) var model: String?

    public init(settings: SettingsStore, services: AgentServices) {
        self.settings = settings; self.services = services
        isOn = settings.snapshot.bool(.aiModeEnabled)
        let config = services.config.config
        let saved = config.provider.flatMap(AgentProviderID.init(rawValue:)) ?? .claude
        provider = saved
        model = config.models[saved.rawValue]
    }
}
#endif
