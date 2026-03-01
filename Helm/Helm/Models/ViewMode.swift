import Foundation

enum ViewMode: String, CaseIterable, Codable {
    case grid
    case list

    var displayName: String {
        switch self {
        case .grid: return "Grid"
        case .list: return "List"
        }
    }

    var systemImageName: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}
