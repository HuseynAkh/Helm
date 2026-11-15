#if os(macOS)
import Foundation
import HelmAgent
import HelmCore

/// What the model's name under the composer offers: every provider whose last check answered, each with the models
/// it listed, and the model requests go to now. It's worked out from what ai.json keeps and from whether a key is
/// saved, so nothing is asked to show it. With more than one model to choose from it's a menu; otherwise the name
/// opens Settings › AI, as it always has.
struct AgentModelMenu: Equatable {
    /// One model of one provider, as the menu offers it and as choosing it saves it.
    struct Choice: Equatable, Hashable {
        let provider: AgentProviderID
        let model: String
    }
    /// One provider's part of the menu: its name, then its models in the order it listed them.
    struct ProviderModels: Equatable {
        let provider: AgentProviderID
        let name: String
        let models: [String]
    }

    let providers: [ProviderModels]
    /// The model requests go to now, which the menu ticks. Nil when none is chosen.
    let current: Choice?

    static let empty = AgentModelMenu(providers: [], current: nil)

    /// Every model on offer, counted once per provider.
    var modelCount: Int { providers.reduce(0) { $0 + $1.models.count } }
    /// Whether there's a choice to make. One model alone stays a plain name.
    var isMenu: Bool { modelCount > 1 }

    /// The menu `config` makes. A provider is offered when its last check answered with models for the address it is
    /// reached at now, and, for a provider that takes a key, while that key is still saved. Each provider offered
    /// leads with the model chosen for it when its list lacks that one, so there's always a way back to it, and the
    /// provider in use is offered with its model even when it has no list, so the tick always has a row. Names that
    /// no provider could have listed are left out, and each provider gives at most `AgentModelInfo.listCap` models.
    static func make(config: AIConfig, hasKey: (AgentSecretID) -> Bool) -> AgentModelMenu {
        let inUse = config.provider.flatMap(AgentProviderID.init(rawValue:))
        var providers: [ProviderModels] = []
        for id in AgentProviderID.allCases {
            var draft = config
            draft.provider = id.rawValue
            guard let profile = try? AgentProviderCatalog.profile(for: draft).get() else { continue }
            var seen: Set<String> = []
            var models = (config.modelLists[profile.secretID.account] ?? [])
                .compactMap { AgentModelInfo(id: $0)?.id }
                .filter { seen.insert($0).inserted }
            if profile.needsKey && !hasKey(profile.secretID) { models = [] }
            models = Array(models.prefix(AgentModelInfo.listCap))
            if let chosen = AgentProviderCatalog.model(for: draft), id == inUse || !models.isEmpty, !models.contains(chosen) {
                models.insert(chosen, at: 0)
            }
            guard !models.isEmpty else { continue }
            // A typed address is named by its host, as the consent line names it; the rest by the provider's name.
            let name = id == .other ? profile.endpoint.hostLabel : profile.name
            providers.append(ProviderModels(provider: id, name: name, models: models))
        }
        let current = inUse.flatMap { id in AgentProviderCatalog.model(for: config).map { Choice(provider: id, model: $0) } }
        return AgentModelMenu(providers: providers, current: current)
    }

    /// The menu as words, for tests and scripted runs: each provider's name, a colon and its models joined by commas,
    /// the ticked one starred, and the providers joined by " | ".
    var summaryForTesting: String {
        providers.map { group in
            group.name + ": " + group.models.map { model in
                current == Choice(provider: group.provider, model: model) ? "*" + model : model
            }.joined(separator: ",")
        }.joined(separator: " | ")
    }
}
#endif
