import Foundation

/// Why bytes couldn't be taken as JSON.
public enum AgentJSONError: Error, Equatable, Sendable {
    /// Nested deeper than `AgentJSON.maxDepth`.
    case tooDeep
    /// Not JSON at all.
    case malformed
}

/// A JSON value. A provider's own items, a tool's schema and a tool call's arguments are all carried as one of these,
/// so they can be kept, compared and sent back unchanged without a type for every provider's shapes.
public indirect enum AgentJSON: Hashable, Sendable, Codable {
    case null, bool(Bool), number(Double), string(String), array([AgentJSON]), object([String: AgentJSON])

    /// The deepest nesting of arrays and objects that is taken in. What a provider sends is not trusted, and a value
    /// nested without end would otherwise be walked without end.
    public static let maxDepth = 32

    /// The value in `data`. Throws `AgentJSONError.tooDeep` for nesting deeper than `maxDepth`, which is found by
    /// counting brackets before anything is decoded, and `.malformed` for bytes that aren't JSON in UTF-8.
    public init(data: Data) throws {
        try Self.checkDepth(of: data)
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let json = AgentJSON(foundationValue: value) else { throw AgentJSONError.malformed }
        self = json
    }

    /// The value as JSON text in UTF-8. With `sortedKeys` an object's keys are written in a fixed order, so the same
    /// value always gives the same bytes. A number with no fraction is written as an integer, a slash is never
    /// escaped, and a number that isn't finite is written as `null`, which JSON has no other word for.
    public func data(sortedKeys: Bool = true) -> Data {
        var text = ""
        spell(into: &text, sortedKeys: sortedKeys)
        return Data(text.utf8)
    }

    // MARK: Codable

    /// Decodes a value nested no deeper than `maxDepth`, counted from the top of what the decoder reads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if decoder.codingPath.count >= Self.maxDepth {
            throw AgentJSONError.tooDeep
        } else if let value = try? container.decode([AgentJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AgentJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: Looking inside

extension AgentJSON {
    /// The member `key` of an object. Nil for any other value and for a missing member.
    subscript(key: String) -> AgentJSON? {
        if case .object(let members) = self { return members[key] }
        return nil
    }
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    var arrayValue: [AgentJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }
    var objectValue: [String: AgentJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }
    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The value in text a person or a model wrote as JSON, when it is an object or an array within the depth limit.
    init?(jsonText text: String) {
        guard let first = text.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }),
              first == "{" || first == "[", let value = try? AgentJSON(data: Data(text.utf8)) else { return nil }
        self = value
    }
}

// MARK: From bytes and to bytes

extension AgentJSON {
    /// Throws `tooDeep` when arrays and objects in `data` nest deeper than `maxDepth`. Brackets inside a string don't
    /// count. Nothing is decoded, so the cost is one pass over the bytes however the data is shaped. Throws
    /// `malformed` for bytes that aren't UTF-8: Foundation's reader would also take UTF-16 and UTF-32, where a quote
    /// byte can sit inside another character and hide the brackets after it from the count.
    static func checkDepth(of data: Data) throws {
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw AgentJSONError.malformed }
        var depth = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > maxDepth { throw AgentJSONError.tooDeep }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
                // A bracket that closes nothing: counting on from below zero would let deeper nesting through.
                if depth < 0 { throw AgentJSONError.malformed }
            default: break
            }
        }
    }

    /// A value as Foundation's JSON reader hands it over. Nil for anything that reader never makes.
    private init?(foundationValue value: Any) {
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            // Foundation keeps true and false as numbers of their own kind, which is the only way to tell them from 1 and 0.
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let text as String: self = .string(text)
        case let items as [Any]:
            var values: [AgentJSON] = []
            values.reserveCapacity(items.count)
            for item in items {
                guard let value = AgentJSON(foundationValue: item) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let members as [String: Any]:
            var values: [String: AgentJSON] = [:]
            values.reserveCapacity(members.count)
            for (key, member) in members {
                guard let value = AgentJSON(foundationValue: member) else { return nil }
                values[key] = value
            }
            self = .object(values)
        default: return nil
        }
    }

    private func spell(into text: inout String, sortedKeys: Bool) {
        switch self {
        case .null: text += "null"
        case .bool(let value): text += value ? "true" : "false"
        case .number(let value): text += Self.numberText(value)
        case .string(let value): Self.spell(string: value, into: &text)
        case .array(let values):
            text += "["
            for (index, value) in values.enumerated() {
                if index > 0 { text += "," }
                value.spell(into: &text, sortedKeys: sortedKeys)
            }
            text += "]"
        case .object(let members):
            text += "{"
            // Sorted by code point, which doesn't change with the Mac's language.
            let keys = sortedKeys ? members.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
                                  : Array(members.keys)
            for (index, key) in keys.enumerated() {
                if index > 0 { text += "," }
                Self.spell(string: key, into: &text)
                text += ":"
                members[key]?.spell(into: &text, sortedKeys: sortedKeys)
            }
            text += "}"
        }
    }

    private static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        // Every whole number up to 2^53 is exact in a Double, so it is written without a fraction.
        if value == value.rounded(), abs(value) <= 9_007_199_254_740_992 { return String(Int64(value)) }
        return "\(value)"
    }

    private static func spell(string: String, into text: inout String) {
        text += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    text += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        text += "\""
    }
}
