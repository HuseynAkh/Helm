// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Value history preserves Back/Forward selection and deduplicates same-location pushes (F-005, B-019).
public struct NavigationHistory: Sendable, Equatable, Codable {
    /// Selection captured from the visible presentation before accepted navigation (B-011).
    public struct Entry: Sendable, Equatable, Codable {
        public let location: Location
        public let selection: Set<ItemID>
        public init(location: Location, selection: Set<ItemID> = []) {
            self.location = location; self.selection = selection
        }
    }
    public private(set) var back: [Entry]
    public private(set) var forward: [Entry]
    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }
    public init(back: [Entry] = [], forward: [Entry] = []) { self.back = back; self.forward = forward }
    @discardableResult
    public mutating func push(current: Entry, movingTo location: Location) -> Bool {
        guard current.location != location else { return false }
        back.append(current); forward.removeAll(); return true
    }
    public mutating func goBack(current: Entry) -> Entry? {
        guard let entry = back.popLast() else { return nil }
        forward.append(current); return entry
    }
    public mutating func goForward(current: Entry) -> Entry? {
        guard let entry = forward.popLast() else { return nil }
        back.append(current); return entry
    }
}
/// A staged load cannot modify committed location/history until its first successful batch (B-069).
public struct PendingNavigation: Sendable, Equatable {
    public let target: Location
    public let intent: NavigationIntent
    public let restoredSelection: Set<ItemID>
    public let generation: Generation
    /// History entries to consume on commit; repeated Back/Forward before the first batch accumulate (F-005).
    public let steps: Int
    public init(target: Location, intent: NavigationIntent, restoredSelection: Set<ItemID> = [], generation: Generation, steps: Int = 1) {
        self.target = target; self.intent = intent
        self.restoredSelection = restoredSelection; self.generation = generation; self.steps = steps
    }
}
