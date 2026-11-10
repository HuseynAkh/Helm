/// Request identity rejects stale asynchronous results (B-014, B-021).
/// The counter wraps at UInt64.max; callers must not retain work across an entire counter cycle.
public struct Generation: Hashable, Sendable, Comparable, Codable {
    public let rawValue: UInt64
    public init(rawValue: UInt64 = 0) { self.rawValue = rawValue }
    public func next() -> Generation { Generation(rawValue: rawValue &+ 1) }
    public static func < (lhs: Generation, rhs: Generation) -> Bool { lhs.rawValue < rhs.rawValue }
}
