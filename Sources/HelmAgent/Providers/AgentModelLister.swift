import Foundation
import HelmCore

/// Reads a provider's model list. Only ids are kept, and only ids `AgentModelInfo` takes; a provider's display
/// names and descriptions are never used. At most `AgentModelInfo.listCap` models are kept.
public enum AgentModelLister {
    /// The models in a list reply, in the order the menu shows them. OpenAI's list mixes its chat models with
    /// image, speech, moderation and embedding ones, so only the ones that can chat are kept, those that start `gpt-`
    /// first; every other provider's order is kept. Ollama's models that run on Ollama's own servers are left out, since what is sent to them leaves this
    /// Mac. Throws `AgentFailure.unreadable` for a reply that isn't a list.
    public static func models(from body: Data, provider: AgentProviderID) throws -> [AgentModelInfo] {
        guard let reply = try? AgentJSON(data: body),
              let entries = reply["data"]?.arrayValue ?? reply["models"]?.arrayValue else { throw AgentFailure.unreadable }
        var seen: Set<String> = [], models: [AgentModelInfo] = []
        for entry in entries {
            guard let id = modelID(of: entry, provider: provider),
                  let model = AgentModelInfo(id: id, label: nil, seesPictures: seesPictures(entry, provider: provider)),
                  seen.insert(model.id).inserted else { continue }
            models.append(model)
        }
        if provider == .openAI {
            let chat = models.filter { Self.canChat($0.id) }
            let gpt = chat.filter { $0.id.hasPrefix(chatPrefix) }.sorted { $0.id < $1.id }
            let rest = chat.filter { !$0.id.hasPrefix(chatPrefix) }.sorted { $0.id < $1.id }
            models = gpt + rest
        }
        return Array(models.prefix(AgentModelInfo.listCap))
    }

    /// The models a ChatGPT plan may use, from OpenAI's list for the signed-in account: those whose visibility is
    /// "list", in the order OpenAI gave, each shown by its display name. Its slug is what a request names. Throws
    /// `AgentFailure.unreadable` for a reply that isn't such a list.
    public static func chatGPTModels(from body: Data) throws -> [AgentModelInfo] {
        guard let reply = try? AgentJSON(data: body), let entries = reply["models"]?.arrayValue else { throw AgentFailure.unreadable }
        var seen: Set<String> = [], models: [AgentModelInfo] = []
        for entry in entries where entry["visibility"]?.stringValue == "list" {
            guard let slug = entry["slug"]?.stringValue,
                  let model = AgentModelInfo(id: slug, label: entry["display_name"]?.stringValue),
                  seen.insert(model.id).inserted else { continue }
            models.append(model)
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
    /// OpenAI's models that answer no chat request, by how their ids start.
    private static let notChat = ["tts-", "whisper-", "dall-e-", "text-embedding-", "omni-moderation-", "davinci-", "babbage-",
                                  "gpt-image-"]

    /// An OpenAI model that answers a chat request: a `gpt-` one, an `o` and a digit, or a `chatgpt-` one.
    private static func canChat(_ id: String) -> Bool {
        guard !notChat.contains(where: { id.hasPrefix($0) }) else { return false }
        if id.hasPrefix(chatPrefix) || id.hasPrefix("chatgpt-") { return true }
        let letters = Array(id)
        return letters.count >= 2 && letters[0] == "o" && letters[1].isNumber
    }
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

    /// What LM Studio's own list says of a model: "vlm" for one that sees pictures, "llm" for one that reads text
    /// only. Nil for any other provider, or an entry from its other list, which doesn't say.
    private static func seesPictures(_ entry: AgentJSON, provider: AgentProviderID) -> Bool? {
        guard provider == .lmStudio, let type = entry["type"]?.stringValue else { return nil }
        switch type {
        case "vlm": return true
        case "llm": return false
        default: return nil
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
