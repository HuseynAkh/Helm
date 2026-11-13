import Foundation
import HelmCore

/// Merges several ranked lists into one by weighted reciprocal rank fusion.
///
/// Each list adds `weight / (k + position)` to every item it holds, with positions counted from 1, so an item near
/// the top of several lists rises above one that tops a single list. Only positions count, never a list's own
/// scores, so lists ranked in different ways can be merged.
public enum RankFusion {
    /// The constant that softens the lead of the first few places. 60 is the value the method was published with.
    public static let k: Double = 60
    /// The weight of each planned query's list, strictest first.
    public static let queryWeights: [Double] = [1.0, 0.85, 0.7, 0.6, 0.5, 0.5]
    /// The weight of the plain search on the person's own words.
    public static let baselineWeight: Double = 0.5

    /// One list of every item the lists hold, best first. An item listed twice in one list counts at its first
    /// place only. Items with the same score keep the order in which they were first seen, reading the lists in
    /// the order given.
    public static func fuse(_ lists: [(weight: Double, ids: [ItemID])]) -> [ItemID] {
        var scores: [ItemID: Double] = [:]
        var order: [ItemID] = []
        for list in lists {
            var counted: Set<ItemID> = []
            for (index, id) in list.ids.enumerated() where counted.insert(id).inserted {
                if scores[id] == nil { order.append(id) }
                scores[id, default: 0] += list.weight / (k + Double(index + 1))
            }
        }
        let firstSeen = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.sorted { left, right in
            let a = scores[left] ?? 0, b = scores[right] ?? 0
            if a != b { return a > b }
            return (firstSeen[left] ?? 0) < (firstSeen[right] ?? 0)
        }
    }
}
