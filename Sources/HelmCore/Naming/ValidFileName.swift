import Foundation

/// Validated single component for F-054–F-057; closes traversal bug B-046.
/// POSIX colons are allowed (Finder displays them as slashes). Whitespace is trimmed.
public struct ValidFileName: Hashable, Sendable, Codable {
    public let value: String
    public var isHidden: Bool { value.hasPrefix(".") }
    public init?(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard FileNameValidator.error(for: value) == nil else { return nil }
        self.value = value
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let valid = ValidFileName(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid file name")
        }
        self = valid
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Central validation for creation and rename (F-054–F-057, B-046).
public enum FileNameValidator {
    public static func validate(_ raw: String) -> Result<ValidFileName, FileNameError> {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let error = error(for: trimmed) { return .failure(error) }
        guard let name = ValidFileName(trimmed) else { return .failure(.empty) }
        return .success(name)
    }
    static func error(for value: String) -> FileNameError? {
        if value.isEmpty { return .empty }
        if value.contains("/") { return .separator }
        if value.contains("\0") { return .nul }
        if value == "." || value == ".." { return .dot }
        if value.utf8.count > 255 { return .tooLong }
        return nil
    }
}
