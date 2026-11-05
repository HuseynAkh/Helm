// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Stable section identity avoids row-index selection bugs (B-011, M18).
public enum FileGroupKey: Hashable, Sendable {
    case all, kind(String), date(ModifiedDateBucket), size(FileSizeBucket), tag(FinderTag), untagged
}

/// Local-calendar buckets; future dates and unavailable dates stay explicit (M18, F-040).
public enum ModifiedDateBucket: Int, CaseIterable, Hashable, Sendable {
    case future, today, yesterday, previous7Days, previous30Days, earlier, unknown
}

/// Decimal byte buckets; unknown metadata is distinct from empty files (B-066, M18).
public enum FileSizeBucket: Int, CaseIterable, Hashable, Sendable {
    case empty, underMegabyte, underGigabyte, gigabyteOrMore, unknown
}

/// Projection retains original item identities and input order within sections (F-038, M18).
public struct FileGroup: Sendable, Equatable {
    public let key: FileGroupKey
    public let items: [FileEntry]
    public init(key: FileGroupKey, items: [FileEntry]) { self.key = key; self.items = items }
}

/// Pure grouping; tag memberships may place an item in several sections (F-040, M18).
public enum FileGrouping {
    public static func groups(_ entries: [FileEntry], by grouping: GroupBy,
                              tags: [ItemID: TagSet] = [:], clock: any HelmClock = SystemHelmClock(),
                              calendar: Calendar = .current) -> [FileGroup] {
        let now = clock.now()
        var order: [FileGroupKey] = []
        var buckets: [FileGroupKey: [FileEntry]] = [:]
        for entry in entries {
            let keys: [FileGroupKey]
            switch grouping {
            case .none: keys = [.all]
            case .kind: keys = [.kind(entry.localizedKindDescription ?? entry.kind.rawValue)]
            case .dateModified: keys = [.date(dateBucket(entry.modificationDate, now: now, calendar: calendar))]
            case .size: keys = [.size(sizeBucket(entry.size))]
            case .tag:
                let itemTags = tags[entry.id]?.tags ?? []
                var seen: Set<FinderTag> = []
                keys = itemTags.isEmpty ? [.untagged] : itemTags.filter { seen.insert($0).inserted }.map { .tag($0) }
            }
            for key in keys {
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: []].append(entry)
            }
        }
        if grouping == .dateModified {
            order.sort { left, right in
                guard case .date(let a) = left, case .date(let b) = right else { return false }
                return a.rawValue < b.rawValue
            }
        } else if grouping == .size {
            order.sort { left, right in
                guard case .size(let a) = left, case .size(let b) = right else { return false }
                return a.rawValue < b.rawValue
            }
        }
        return order.map { FileGroup(key: $0, items: buckets[$0] ?? []) }
    }
    public static func dateBucket(_ date: Date, now: Date, calendar: Calendar) -> ModifiedDateBucket {
        guard date != .distantPast, date.timeIntervalSinceReferenceDate.isFinite else { return .unknown }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        guard let age = calendar.dateComponents([.day], from: day, to: today).day else { return .unknown }
        switch age {
        case ..<0: return .future
        case 0: return .today
        case 1: return .yesterday
        case 2...7: return .previous7Days
        case 8...30: return .previous30Days
        default: return .earlier
        }
    }
    public static func sizeBucket(_ bytes: Int64) -> FileSizeBucket {
        switch bytes {
        case ..<0: return .unknown
        case 0: return .empty
        case 1..<1_000_000: return .underMegabyte
        case 1_000_000..<1_000_000_000: return .underGigabyte
        default: return .gigabyteOrMore
        }
    }
}
