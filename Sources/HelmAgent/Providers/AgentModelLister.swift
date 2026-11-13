import Foundation
import HelmCore

/// Reads a provider's model list. Only ids are kept, and only ids `AgentModelInfo` takes; a provider's display
/// names and descriptions are never used. At most `AgentModelInfo.listCap` models are kept.
public enum AgentModelLister {
    /// The models in a list reply, in the order the menu shows them. OpenAI's list mixes its chat models with
    /// image, speech and embedding ones, so the ids that start `gpt-` come first; every other provider's order is
    /// kept. Ollama's models that run on Ollama's own servers are left out, since what is sent to them leaves this
    /// Mac. Throws `AgentFailure.unreadable` for a reply that isn't a list.
    public static func models(from body: Data, provider: AgentProviderID) throws -> [AgentModelInfo] {
        guard let reply = try? AgentJSON(data: body),
              let entries = reply["data"]?.arrayValue ?? reply["models"]?.arrayValue else { throw AgentFailure.unreadable }
        var seen: Set<String> = [], models: [AgentModelInfo] = []
        for entry in entries {
            guard let id = modelID(of: entry, provider: provider), let model = AgentModelInfo(id: id),
                  seen.insert(model.id).inserted else { continue }
            models.append(model)
        }
        if provider == .openAI {
            let chat = models.filter { $0.id.hasPrefix(chatPrefix) }.sorted { $0.id < $1.id }
            let rest = models.filter { !$0.id.hasPrefix(chatPrefix) }.sorted { $0.id < $1.id }
            models = chat + rest
        }
        return Array(models.prefix(AgentModelInfo.listCap))
    }

    /// The model picked for the person until they pick one: the provider's own preselected model when the list
    /// has it, else the first listed. A typed address preselects nothing.
    public static func preselected(_ models: [AgentModelInfo], provider: AgentProviderID) -> String? {
        if let preferred = AgentProviderCatalog.defaultModel(provider), models.contains(where: { $0.id == preferred }) {
            return preferred
        }
        return provider == .other ? nil : models.first?.id
    }

    private static let chatPrefix = "gpt-"
    /// Gemini names a model `models/<id>`; the id alone is what a request takes.
    private static let geminiPrefix = "models/"

    /// The id an entry stands for. Nil for an entry that is left out.
    private static func modelID(of entry: AgentJSON, provider: AgentProviderID) -> String? {
        if let id = entry.stringValue { return id }
        guard case .object = entry else { return nil }
        // Embedding models answer no chat request.
        if let type = entry["type"]?.stringValue, type.hasPrefix("embedding") { return nil }
        switch provider {
        case .ollama:
            guard !isRemote(entry) else { return nil }
            return entry["name"]?.stringValue ?? entry["model"]?.stringValue
        case .gemini:
            if let methods = entry["supportedGenerationMethods"]?.arrayValue,
               !methods.contains(.string("generateContent")) { return nil }
            guard let name = entry["name"]?.stringValue ?? entry["id"]?.stringValue else { return nil }
            return name.hasPrefix(geminiPrefix) ? String(name.dropFirst(geminiPrefix.count)) : name
        case .claude, .openAI, .grok, .lmStudio, .other:
            return entry["id"]?.stringValue ?? entry["key"]?.stringValue ?? entry["name"]?.stringValue
        }
    }

    /// An Ollama model that runs on Ollama's servers: it names a remote model or host, or its tag says cloud.
    private static func isRemote(_ entry: AgentJSON) -> Bool {
        for key in ["remote_model", "remote_host"] {
            if let value = entry[key], value != .null { return true }
        }
        let name = entry["name"]?.stringValue ?? entry["model"]?.stringValue ?? ""
        guard let tag = name.split(separator: ":").last, name.contains(":") else { return false }
        return tag == "cloud" || tag.hasSuffix("-cloud")
    }
}
