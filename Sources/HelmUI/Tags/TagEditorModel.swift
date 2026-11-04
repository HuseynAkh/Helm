// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Tag edit proposal preserves unknown raw metadata and private stars (F-029, M18).
public struct TagEditorModel: Equatable, Sendable {
    public var tags: TagSet
    public var name: String
    public var color: FinderTagColor
    public init(tags: TagSet, name: String = "", color: FinderTagColor = .none) {
        self.tags = tags; self.name = name; self.color = color
    }
    public var proposedTag: FinderTag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return FinderTag(name: trimmed, colorIndex: color.rawValue)
    }
    public var canAdd: Bool { proposedTag.map { !tags.tags.contains($0) } ?? false }
    public mutating func add() {
        guard canAdd, let tag = proposedTag else { return }
        tags.add(tag); name = ""
    }
    public mutating func remove(_ tag: FinderTag) { tags.remove(tag) }
    public static func label(_ color: FinderTagColor) -> String {
        switch color {
        case .none: return "None"
        case .gray: return "Gray"
        case .green: return "Green"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .orange: return "Orange"
        }
    }
}
