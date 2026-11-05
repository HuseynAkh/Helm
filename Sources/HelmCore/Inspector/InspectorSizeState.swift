// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-050 exact-byte totals distinguish incomplete work from zero (B-066, audit C-22).
public enum InspectorSizeState: Equatable, Sendable {
    case calculating
    case partial(InspectorSizeTotal)
    case final(InspectorSizeTotal)
    case unavailable

    /// Aggregates disjoint item/subtree totals supplied by a cancellable adapter.
    /// Negative metadata is unknown; overflow saturates and remains explicitly flagged.
    public static func aggregate(_ states: [InspectorSizeState]) -> InspectorSizeState {
        guard !states.isEmpty else { return .unavailable }
        var totals: [InspectorSizeTotal] = []
        var complete: Bool = true
        var calculating: Bool = false
        for state in states {
            switch state {
            case .calculating: complete = false; calculating = true
            case .unavailable: complete = false
            case .partial(let total): totals.append(total); complete = false
            case .final(let total): totals.append(total)
            }
        }
        guard !totals.isEmpty else { return calculating ? .calculating : .unavailable }
        var bytes: Int64 = 0
        var count: Int64 = 0
        var overflow: Bool = false
        for total in totals {
            let byteSum = bytes.addingReportingOverflow(total.bytes)
            let countSum = count.addingReportingOverflow(total.itemCount)
            bytes = byteSum.overflow ? .max : byteSum.partialValue
            count = countSum.overflow ? .max : countSum.partialValue
            overflow = overflow || total.overflowed || byteSum.overflow || countSum.overflow
        }
        let result = InspectorSizeTotal(bytes: bytes, itemCount: count, overflowed: overflow)
        return complete ? .final(result) : .partial(result)
    }
    public static func metadata(bytes: Int64, isDirectory: Bool) -> InspectorSizeState {
        guard !isDirectory else { return .calculating }
        guard bytes >= 0 else { return .unavailable }
        return .final(InspectorSizeTotal(bytes: bytes, itemCount: 1))
    }
}

/// F-050 nonnegative exact-byte summary, without formatting away byte precision (B-066).
public struct InspectorSizeTotal: Equatable, Sendable {
    public let bytes: Int64
    public let itemCount: Int64
    public let overflowed: Bool
    public init(bytes: Int64, itemCount: Int64, overflowed: Bool = false) {
        self.bytes = max(0, bytes); self.itemCount = max(0, itemCount)
        self.overflowed = overflowed
    }
}
