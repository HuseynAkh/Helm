// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Stable app-owned window identity is independent of controller lifetime (F-001, F-068).
public struct AppWindowID: Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Creation order and most-recent activation are explicit; close never terminates the app (F-001).
public struct WindowRegistry: Equatable, Sendable {
    public private(set) var orderedIDs: [AppWindowID] = []
    private var activationOrder: [AppWindowID] = []
    public var first: AppWindowID? { orderedIDs.first }
    public var frontmost: AppWindowID? { activationOrder.last }
    public var closeOrder: [AppWindowID] { Array(activationOrder.reversed()) }
    public init() {}
    @discardableResult public mutating func register(_ id: AppWindowID) -> Bool {
        guard !orderedIDs.contains(id) else { return false }
        orderedIDs.append(id); activationOrder.append(id); return true
    }
    @discardableResult public mutating func activate(_ id: AppWindowID) -> Bool {
        guard orderedIDs.contains(id) else { return false }
        activationOrder.removeAll { $0 == id }; activationOrder.append(id); return true
    }
    @discardableResult public mutating func close(_ id: AppWindowID) -> Bool {
        guard orderedIDs.contains(id) else { return false }
        orderedIDs.removeAll { $0 == id }; activationOrder.removeAll { $0 == id }; return true
    }
    /// NSApplication supplies visibility, because minimized and hidden are UI states.
    public func needsWindowOnReopen(hasVisibleWindows: Bool) -> Bool { !hasVisibleWindows }
}
