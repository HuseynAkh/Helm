/// Stored values preserve the existing grid/list preference (F-036).
public enum ViewMode: String, CaseIterable, Sendable, Codable {
    case grid, list
    public var displayName: String { self == .grid ? "Grid" : "List" }
    public var systemImageName: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}
/// Sidebar sections retain Places and Tree modes (F-027, F-031).
public enum SidebarMode: String, CaseIterable, Sendable, Codable { case places, tree }
