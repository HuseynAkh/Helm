// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Editable projection of immutable per-folder options (F-036, F-040, F-065).
public struct ViewOptionsModel: Equatable, Sendable {
    public var viewMode: ViewMode
    public var sortField: ItemSort.Field
    public var ascending: Bool
    public var directoriesFirst: Bool
    public var groupBy: GroupBy
    public var iconSize: Double
    public var columns: Set<ListColumn>
    public var textSize: Double
    public init(options: ViewOptions) {
        viewMode = options.viewMode; sortField = options.sort.field
        ascending = options.sort.ascending; directoriesFirst = options.sort.directoriesFirst
        groupBy = options.groupBy; iconSize = options.iconSize
        columns = options.showColumns; textSize = options.textSize
    }
    public var options: ViewOptions {
        ViewOptions(viewMode: viewMode,
                    sort: ItemSort(field: sortField, ascending: ascending, directoriesFirst: directoriesFirst),
                    groupBy: groupBy, iconSize: iconSize, showColumns: columns, textSize: textSize)
    }
    public static let groups: [GroupBy] = [.none, .kind, .dateModified, .size, .tag]
    public static func label(_ rawValue: String) -> String {
        switch rawValue {
        case "dateModified": return "Date Modified"
        case "dateCreated": return "Date Created"
        case "dateLastOpened": return "Date Last Opened"
        case "dateAdded": return "Date Added"
        default: return rawValue.capitalized
        }
    }
}
