import Foundation

/// Pure prefix matching for F-041's list/grid type-select and Space routing (B-060).
/// A run expires after one second by default; exactly the timeout starts a new run.
/// Native AppKit timing is unspecified in the legacy app; this is the shared grid policy.
public struct TypeSelect: Sendable {
    public private(set) var prefix: String = ""
    private var lastInput: Date?
    private let clock: any HelmClock
    public let timeout: TimeInterval
    public init(clock: any HelmClock = SystemHelmClock(), timeout: TimeInterval = 1) {
        self.clock = clock
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : 1
    }
    public var isActive: Bool {
        guard let lastInput, !prefix.isEmpty else { return false }
        let elapsed = clock.now().timeIntervalSince(lastInput)
        return elapsed >= 0 && elapsed < timeout
    }
    /// Returns the first visible matching row; failed prefixes remain until timeout/reset.
    public mutating func select(typing text: String, names: [String]) -> Int? {
        guard !text.isEmpty, text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if !isActive { prefix = "" }
        prefix += text
        lastInput = clock.now()
        return Self.match(prefix: prefix, names: names)
    }
    public mutating func reset() { prefix = ""; lastInput = nil }
    public static func match(prefix: String, names: [String]) -> Int? {
        guard !prefix.isEmpty else { return nil }
        let needle = FileNameComparison.key(prefix, caseSensitive: false)
        return names.firstIndex { FileNameComparison.key($0, caseSensitive: false).hasPrefix(needle) }
    }
}
