import Foundation

/// Completion request owns its generation so programmatic edits cannot orphan it (F-016, F-017).
public struct CompletionRequest: Hashable, Sendable {
    public let parent: URL
    public let prefix: String
    public let isSlashBrowsing: Bool
    public let showHidden: Bool
    public let generation: Generation
    public init(parent: URL, prefix: String, isSlashBrowsing: Bool, showHidden: Bool, generation: Generation) {
        self.parent = parent; self.prefix = prefix; self.isSlashBrowsing = isSlashBrowsing
        self.showHidden = showHidden; self.generation = generation
    }
}
/// Minimal editor state for F-012–F-024. Rows carry metadata; presentation labels belong to the address-bar lane.
public struct AddressBarState: Sendable, Equatable {
    public var text: String
    public var rows: [FileEntry]
    public var selectedIndex: Int?
    public var isPopupVisible: Bool
    public var isEditing: Bool
    public init(text: String = "", rows: [FileEntry] = [], selectedIndex: Int? = nil,
                isPopupVisible: Bool = false, isEditing: Bool = false) {
        self.text = text; self.rows = rows; self.selectedIndex = selectedIndex
        self.isPopupVisible = isPopupVisible; self.isEditing = isEditing
    }
}
/// Value-only editor input seam (F-019, F-021); the address-bar reducer supplies behaviour.
public enum AddressBarAction: Sendable, Equatable {
    case beginEditing, textChanged(String), select(Int?), completions(Generation, [FileEntry]), accept, cancel
}
