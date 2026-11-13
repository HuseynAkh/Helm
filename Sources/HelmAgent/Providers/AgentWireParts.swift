import Foundation
import HelmCore

/// What the three wire adapters share: how one line of a streamed reply is taken, the token ceilings, the checks
/// made before a body is built, and how the JSON a model wrote is found in its text.
enum AgentWireParts {
    /// The most a Claude turn and a hosted Chat Completions turn may write.
    static let maxTokens = 16_000
    /// The most a Responses turn may write. Reasoning counts against it, so it is larger.
    static let maxOutputTokens = 32_000
    /// How many places a `{` is tried when the first JSON object in a text is looked for.
    static let objectAttempts = 64

    /// What one line of a reply holds.
    enum Line: Equatable {
        /// An empty line, a `:` comment, an `event:` name or another field Helm doesn't read.
        case nothing
        /// `[DONE]`, which ends a Chat Completions stream.
        case done
        /// A JSON object.
        case json(AgentJSON)
        /// A data line that isn't a JSON object within the depth limit.
        case unreadable
    }

    /// One line as a stream sends it. The `data:` field is what counts; a line that is a JSON object on its own is
    /// taken too, for a server that streams bare JSON lines.
    static func line(_ text: String) -> Line {
        var body = Substring(text)
        if body.hasSuffix("\r") { body = body.dropLast() }
        if body.hasPrefix("data:") {
            body = body.dropFirst("data:".count)
        } else if !body.hasPrefix("{") {
            return .nothing
        }
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .nothing }
        if trimmed == "[DONE]" { return .done }
        guard let value = try? AgentJSON(data: Data(trimmed.utf8)), case .object = value else { return .unreadable }
        return .json(value)
    }

    /// Throws `noSuchModel` for a model name no provider could have listed, so the body never carries one.
    static func check(model: String) throws {
        guard AgentModelInfo(id: model) != nil else { throw AgentFailure.noSuchModel }
    }

    /// The first JSON object in a model's text, for a server that answered a structured question in words around
    /// the JSON or in a fenced block. Nil when the text holds none.
    static func firstObject(in text: String) -> AgentJSON? {
        let scalars = Array(text.unicodeScalars)
        var start = 0, attempts = 0
        while start < scalars.count, attempts < objectAttempts {
            guard let opening = scalars[start...].firstIndex(of: "{") else { return nil }
            attempts += 1
            if let close = closingBrace(in: scalars, from: opening) {
                var piece = String.UnicodeScalarView()
                piece.append(contentsOf: scalars[opening...close])
                if let value = try? AgentJSON(data: Data(String(piece).utf8)), case .object = value { return value }
            }
            start = opening + 1
        }
        return nil
    }

    /// Where the object that opens at `opening` closes, with braces inside strings left out of the count.
    private static func closingBrace(in scalars: [Unicode.Scalar], from opening: Int) -> Int? {
        var depth = 0, inString = false, escaped = false
        for index in opening..<scalars.count {
            let scalar = scalars[index]
            if inString {
                if escaped { escaped = false }
                else if scalar == "\\" { escaped = true }
                else if scalar == "\"" { inString = false }
                continue
            }
            switch scalar {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    /// A whole number as JSON holds it, when it is one.
    static func integer(_ value: AgentJSON?) -> Int? {
        guard let number = value?.numberValue, number == number.rounded(), abs(number) < 1_000_000_000 else { return nil }
        return Int(number)
    }

    /// The text of a JSON string that holds text, and nil for anything else or an empty string.
    static func nonEmpty(_ value: AgentJSON?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }
}
