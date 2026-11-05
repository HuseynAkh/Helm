// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import HelmCore

/// Draft toolbar layout enforces independent keyboard entry points (F-003/F-043, M24).
public struct ToolbarCustomizationModel: Equatable, Sendable {
    public var items: [HelmCore.ToolbarItem]
    public var reachableKeyboardCommands: Set<ToolbarCommand>
    public init(items: [HelmCore.ToolbarItem] = HelmCore.ToolbarItem.defaultLayout,
                reachableKeyboardCommands: Set<ToolbarCommand>) {
        self.items = items; self.reachableKeyboardCommands = reachableKeyboardCommands
    }
    public var issues: [ToolbarLayoutIssue] {
        ToolbarLayoutValidation.validate(items, reachableKeyboardCommands: reachableKeyboardCommands)
    }
    public var canApply: Bool { issues.isEmpty }
    public mutating func add(_ item: HelmCore.ToolbarItem) {
        if item == .flexibleSpace || !items.contains(item) { items.append(item) }
    }
    public mutating func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
    }
    /// Move to a final row index, used equally by drag and keyboard buttons.
    public mutating func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source), items.indices.contains(destination), source != destination else { return }
        let item = items.remove(at: source)
        items.insert(item, at: destination)
    }
    public mutating func restoreDefaults() { items = HelmCore.ToolbarItem.defaultLayout }
    public static func label(_ item: HelmCore.ToolbarItem) -> String {
        switch item {
        case .sidebar: return "Toggle Sidebar"
        case .navigation: return "Navigation"
        case .location: return "Path"
        case .viewMode: return "View Mode"
        case .search: return "Search"
        case .flexibleSpace: return "Flexible Space"
        }
    }
    /// Command IDs let the host install routes even when toolbar controls are absent.
    public static let requiredCommands: [CommandID] = [.location, .find]
}
