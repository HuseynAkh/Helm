// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Bounded LRU value with canonical directory identity and distinct virtual locations (F-065, B-031).
/// Reads touch recency; missing folders use current defaults without consuming a slot.
public struct ViewOptionsStore: Sendable {
    public let capacity: Int
    public var defaults: ViewOptions
    private var values: [Location: ViewOptions] = [:]
    private var order: [Location] = []
    public init(capacity: Int = 256, defaults: ViewOptions = ViewOptions()) {
        self.capacity = max(0, capacity); self.defaults = defaults
    }
    public var count: Int { values.count }
    public var locationsLeastRecentlyUsedFirst: [Location] { order }
    public mutating func options(for location: Location) -> ViewOptions {
        let key = canonical(location)
        guard let value = values[key] else { return defaults }
        touch(key)
        return value
    }
    public mutating func set(_ options: ViewOptions, for location: Location) {
        guard capacity > 0 else { return }
        let key = canonical(location)
        values[key] = options; touch(key)
        while order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
    }
    public mutating func remove(for location: Location) {
        let key = canonical(location)
        values.removeValue(forKey: key); order.removeAll { $0 == key }
    }
    /// Decode before mutation so corrupt or future data cannot discard existing preferences.
    public mutating func restore(_ data: Data?, for location: Location,
                                 using codec: any ViewOptionsSerialization = JSONViewOptionsSerialization()) throws {
        guard let data else { remove(for: location); return }
        let options = try codec.decode(data)
        set(options, for: location)
    }
    public func serialized(for location: Location,
                           using codec: any ViewOptionsSerialization = JSONViewOptionsSerialization()) throws -> Data? {
        guard let options = values[canonical(location)] else { return nil }
        return try codec.encode(options)
    }
    private mutating func touch(_ key: Location) { order.removeAll { $0 == key }; order.append(key) }
    private func canonical(_ location: Location) -> Location {
        if case .directory(let url) = location { return .directory(url.standardizedFileURL) }
        return location
    }
}
