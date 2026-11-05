// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-050 aggregate fields distinguish absent metadata, no selection and mixed values.
public enum InspectorValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case unavailable, mixed
    case value(Value)
    public init(values: [Value]) {
        guard let first = values.first else { self = .unavailable; return }
        self = values.dropFirst().allSatisfy { $0 == first } ? .value(first) : .mixed
    }
    public var mixedLabel: String? { self == .mixed ? "mixed" : nil }
}

/// Editable F-050 attributes; hidden flags and hidden extensions are separate concepts.
public enum InspectorField: String, CaseIterable, Hashable, Sendable, Codable {
    case name, locked, hidden, hiddenExtension, tags, comment, defaultApplication, permissions
}

/// Typed F-050/F-062 requests; application changes are per-file, never implicit Change All.
public enum InspectorAttribute: Equatable, Sendable {
    case name(String), locked(Bool), hidden(Bool), hiddenExtension(Bool)
    case tags([String]), comment(String), defaultApplication(URL?), permissions(UInt16)
    public var field: InspectorField {
        switch self {
        case .name: return .name
        case .locked: return .locked
        case .hidden: return .hidden
        case .hiddenExtension: return .hiddenExtension
        case .tags: return .tags
        case .comment: return .comment
        case .defaultApplication: return .defaultApplication
        case .permissions: return .permissions
        }
    }
}

/// Adapter-supplied F-050 metadata. Missing attributes remain unsupported.
/// Explicit capabilities avoid assuming ownership from a readable listing.
public struct InspectorItem: Equatable, Sendable {
    public let id: ItemID
    public let url: URL
    public let isDirectory: Bool
    public let attributes: [InspectorField: InspectorAttribute]
    public let editableFields: Set<InspectorField>
    public init(url: URL, isDirectory: Bool = false, attributes: [InspectorAttribute],
                editableFields: Set<InspectorField> = []) {
        self.id = ItemID(url: url); self.url = url; self.isDirectory = isDirectory
        self.attributes = attributes.reduce(into: [:]) { $0[$1.field] = $1 }
        self.editableFields = editableFields
    }
}
