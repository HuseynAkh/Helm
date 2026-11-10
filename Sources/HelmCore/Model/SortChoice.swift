import Foundation

/// A sort said in plain words, so the direction is never left to an arrow (Nautilus's own sort menu reads this way).
public struct SortChoice: Equatable, Sendable {
    public let title: String
    public let shortTitle: String
    public let field: ItemSort.Field
    public let ascending: Bool
    public init(title: String, shortTitle: String, field: ItemSort.Field, ascending: Bool) {
        self.title = title; self.shortTitle = shortTitle; self.field = field; self.ascending = ascending
    }

    public static let all: [SortChoice] = [
        SortChoice(title: "Name A–Z", shortTitle: "A–Z", field: .name, ascending: true),
        SortChoice(title: "Name Z–A", shortTitle: "Z–A", field: .name, ascending: false),
        SortChoice(title: "Newest First", shortTitle: "Newest", field: .dateModified, ascending: false),
        SortChoice(title: "Oldest First", shortTitle: "Oldest", field: .dateModified, ascending: true),
        SortChoice(title: "Largest First", shortTitle: "Largest", field: .size, ascending: false),
        SortChoice(title: "Smallest First", shortTitle: "Smallest", field: .size, ascending: true),
        SortChoice(title: "Kind A–Z", shortTitle: "Kind A–Z", field: .kind, ascending: true),
        SortChoice(title: "Kind Z–A", shortTitle: "Kind Z–A", field: .kind, ascending: false)
    ]
    public static let bestMatch = SortChoice(title: "Best Match", shortTitle: "Best Match", field: .relevance, ascending: true)
    /// Recent's own orders. They're kept out of `all`, which every folder offers.
    public static let mostRecentFirst = SortChoice(title: "Most Recent First", shortTitle: "Most Recent", field: .lastOpened, ascending: false)
    public static let leastRecentFirst = SortChoice(title: "Least Recent First", shortTitle: "Least Recent", field: .lastOpened, ascending: true)

    /// The choice describing a sort. Relevance has one direction, so it always reads the same.
    public static func matching(_ sort: ItemSort) -> SortChoice {
        if sort.field == .relevance { return bestMatch }
        if sort.field == .lastOpened { return sort.ascending ? leastRecentFirst : mostRecentFirst }
        return all.first { $0.field == sort.field && $0.ascending == sort.ascending } ?? all[0]
    }
    public func applied(to sort: ItemSort) -> ItemSort {
        ItemSort(field: field, ascending: ascending, directoriesFirst: sort.directoriesFirst)
    }
}

/// Sorting by field, Nautilus-style: pick a field, and pick it again to reverse it.
public struct SortField: Equatable, Sendable, Identifiable {
    public let field: ItemSort.Field
    public let title: String
    /// The direction a field starts in: names and kinds from A, dates and sizes from the newest or largest.
    public let startsAscending: Bool
    public var id: String { field.rawValue }
    public init(field: ItemSort.Field, title: String, startsAscending: Bool) {
        self.field = field; self.title = title; self.startsAscending = startsAscending
    }

    public static let all: [SortField] = [
        SortField(field: .name, title: "Name", startsAscending: true),
        SortField(field: .dateModified, title: "Modified", startsAscending: false),
        SortField(field: .size, title: "Size", startsAscending: false),
        SortField(field: .kind, title: "Kind", startsAscending: true)
    ]
    /// Recent's own field: the last time Helm opened each item, most recent first. Only Recent offers it,
    /// so it isn't in `all`.
    public static let lastOpened = SortField(field: .lastOpened, title: "Last Opened", startsAscending: false)

    /// The field a sort uses, Recent's Last Opened included, for naming it ("Sorted by Last Opened"). Nil for
    /// Best Match, which isn't a field you choose.
    public static func describing(_ field: ItemSort.Field) -> SortField? {
        (all + [lastOpened]).first { $0.field == field }
    }

    /// Choosing the field that's already sorted reverses it. Choosing another starts it in its own direction.
    public static func pressing(_ field: ItemSort.Field, on sort: ItemSort) -> ItemSort {
        if field == .relevance { return ItemSort(field: .relevance, ascending: true, directoriesFirst: sort.directoriesFirst) }
        if field == sort.field { return ItemSort(field: field, ascending: !sort.ascending, directoriesFirst: sort.directoriesFirst) }
        let start = describing(field)?.startsAscending ?? true
        return ItemSort(field: field, ascending: start, directoriesFirst: sort.directoriesFirst)
    }

    /// The direction in words, such as "A to Z" or "Newest first".
    public static func direction(_ field: ItemSort.Field, ascending: Bool) -> String {
        switch field {
        case .name, .kind: return ascending ? "A to Z" : "Z to A"
        case .dateModified: return ascending ? "Oldest first" : "Newest first"
        case .size: return ascending ? "Smallest first" : "Largest first"
        case .relevance: return "Best first"
        case .lastOpened: return ascending ? "Least recent first" : "Most recent first"
        }
    }
}

/// Text and icon sizes as percentages of the defaults, stepped the way a browser zooms.
public enum ContentZoom {
    public static let defaultTextPoints = 14.0
    public static let defaultIconPixels = 96.0
    /// Text runs from 80% to 170% in steps of 10%, which keeps every step inside the 11 to 24 point setting.
    public static let textPercents = 80...170
    public static let iconRange = 48.0...128.0
    public static let iconStep = 16.0

    public static func textPercent(_ points: Double) -> Int { Int((points / defaultTextPoints * 100).rounded()) }
    public static func iconPercent(_ pixels: Double) -> Int { Int((pixels / defaultIconPixels * 100).rounded()) }
    public static func textPoints(percent: Int) -> Double {
        Double(min(textPercents.upperBound, max(textPercents.lowerBound, percent))) / 100 * defaultTextPoints
    }

    /// One step up or down from any size, landing on the next whole 10% even if the size started between steps.
    public static func steppedText(_ points: Double, by steps: Int) -> Double {
        let tenths = points / defaultTextPoints * 10
        var level = steps > 0 ? (tenths + 0.001).rounded(.down) : (tenths - 0.001).rounded(.up)
        level += Double(steps)
        let next = textPoints(percent: Int(level) * 10)
        // A size set outside the steps never moves the wrong way.
        return steps > 0 ? max(next, points) : min(next, points)
    }
    public static func steppedIcons(_ pixels: Double, by steps: Int) -> Double {
        let level = steps > 0 ? ((pixels + 0.001) / iconStep).rounded(.down) : ((pixels - 0.001) / iconStep).rounded(.up)
        return min(iconRange.upperBound, max(iconRange.lowerBound, (level + Double(steps)) * iconStep))
    }
    public static func canStepText(_ points: Double, by steps: Int) -> Bool { steppedText(points, by: steps) != points }
    public static func canStepIcons(_ pixels: Double, by steps: Int) -> Bool { steppedIcons(pixels, by: steps) != pixels }
}
