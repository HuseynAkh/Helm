// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Finder metadata stays separate from Helm stars (F-029, M18).
/// The exact string is retained, including missing, malformed or future color suffixes.
public struct FinderTag: Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(name: String, colorIndex: Int) { rawValue = "\(name)\n\(colorIndex)" }
    public var name: String {
        guard let separator = rawValue.lastIndex(of: "\n") else { return rawValue }
        return String(rawValue[..<separator])
    }
    public var colorIndex: Int? {
        guard let separator = rawValue.lastIndex(of: "\n") else { return nil }
        return Int(rawValue[rawValue.index(after: separator)...])
    }
    public var color: FinderTagColor? { colorIndex.flatMap(FinderTagColor.init(rawValue:)) }
}

/// Finder's color indices; unknown indices remain in FinderTag (M18, F-029).
public enum FinderTagColor: Int, CaseIterable, Sendable, Codable {
    case none = 0, gray, green, purple, blue, yellow, red, orange
}

/// Ordered metadata entries preserve unrelated and unknown tags on edits (M18, F-029).
public struct TagSet: Equatable, Sendable, Codable {
    public private(set) var tags: [FinderTag]
    public init(tags: [FinderTag] = []) { self.tags = tags }
    public mutating func add(_ tag: FinderTag) {
        if !tags.contains(tag) { tags.append(tag) }
    }
    public mutating func remove(_ tag: FinderTag) { tags.removeAll { $0 == tag } }
}

/// Binary plist codec for com.apple.metadata:_kMDItemUserTags, independent of I/O (M18).
public enum FinderTagCodec {
    public static let attributeName: String = "com.apple.metadata:_kMDItemUserTags"
    public static func decode(_ data: Data) throws -> TagSet {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let entries = plist as? [String] else { throw FinderTagCodecError.expectedStringArray }
        return TagSet(tags: entries.map { FinderTag(rawValue: $0) })
    }
    public static func encode(_ tags: TagSet) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: tags.tags.map(\.rawValue),
                                           format: .binary, options: 0)
    }
}

/// Invalid metadata is rejected rather than overwritten (M18, F-029).
public enum FinderTagCodecError: Error { case expectedStringArray }
