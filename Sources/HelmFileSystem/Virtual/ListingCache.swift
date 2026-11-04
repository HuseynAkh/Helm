import Foundation
import HelmCore

/// Entry-count bounded LRU separates hidden and visible listings (F-042, B-009).
public actor ListingCache {
    private struct Key: Hashable { let location: Location; let showHidden: Bool }
    private struct Record {
        let entries: [FileEntry]
        let token: ChangeToken
        let date: Date
        var access: UInt64
    }
    private var records: [Key: Record] = [:]
    private var counter: UInt64 = 0
    private let capacity: Int
    private let ttl: TimeInterval
    private let clock: any HelmClock
    private var enabled = true
    #if os(macOS)
    private var pressureSource: DispatchSourceMemoryPressure?
    #endif
    public init(capacity: Int = 200_000, ttl: TimeInterval = 3, clock: any HelmClock = SystemHelmClock()) {
        self.capacity = max(0, capacity); self.ttl = max(0, ttl); self.clock = clock
    }
    public func entries(for location: Location, showHidden: Bool, token: ChangeToken) -> [FileEntry]? {
        let key = Key(location: location, showHidden: showHidden)
        guard enabled, var record = records[key] else { return nil }
        guard record.token == token && clock.now().timeIntervalSince(record.date) < ttl else {
            records.removeValue(forKey: key); return nil
        }
        counter &+= 1; record.access = counter; records[key] = record
        return record.entries
    }
    public func store(_ entries: [FileEntry], for location: Location, showHidden: Bool, token: ChangeToken) {
        let key = Key(location: location, showHidden: showHidden)
        records.removeValue(forKey: key)
        guard enabled && entries.count <= capacity else { return }
        counter &+= 1
        records[key] = Record(entries: entries, token: token, date: clock.now(), access: counter)
        while entryCount > capacity, let oldest = records.min(by: { $0.value.access < $1.value.access })?.key {
            records.removeValue(forKey: oldest)
        }
    }
    public func invalidate(_ location: Location) { records = records.filter { $0.key.location != location } }
    public func invalidate(directories: Set<URL>) { for directory in directories { invalidate(.directory(directory)) } }
    public func purge() { records.removeAll() }
    /// Composition root starts this once; Linux relies on the entry cap and explicit purge.
    public func startMemoryPressureObservation() {
        #if os(macOS)
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in Task { await self?.purge() } }
        pressureSource = source
        source.resume()
        #endif
    }
    deinit {
        #if os(macOS)
        pressureSource?.cancel()
        #endif
    }
    public func setEnabled(_ value: Bool) { enabled = value; if !value { purge() } }
    public var entryCount: Int { records.values.reduce(0) { $0 + $1.entries.count } }
}
