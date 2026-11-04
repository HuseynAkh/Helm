// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

/// AppKit-independent modifier bits preserve the F-066 legacy shortcut masks.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

/// A raw key equivalent preserves uppercase N/H and control characters (F-066).
public struct KeyBinding: Hashable, Sendable {
    public let command: CommandID
    public let key: String
    public let modifiers: KeyModifiers
    public init(command: CommandID, key: String, modifiers: KeyModifiers = .command) {
        self.command = command; self.key = key; self.modifiers = modifiers
    }
    /// Uppercase ASCII letters imply Shift in AppKit, even with the default mask (Home).
    public var effectiveModifiers: KeyModifiers {
        if key.count == 1, let scalar = key.unicodeScalars.first, (65...90).contains(scalar.value) {
            return modifiers.union(.shift)
        }
        return modifiers
    }
    public var displayString: String {
        guard !key.isEmpty else { return "" }
        let flags = effectiveModifiers
        let prefix = [(KeyModifiers.control, "⌃"), (.option, "⌥"), (.command, "⌘"), (.shift, "⇧")]
            .filter { flags.contains($0.0) }.map { $0.1 }.joined()
        let names: [String: String] = ["\r": "↩", "\u{8}": "⌫", " ": "Space",
            "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→",
            "\t": "⇥", "\u{1b}": "⎋"]
        return prefix + (names[key] ?? key.uppercased())
    }
}

/// A pair of simultaneously enabled actions sharing a key (B-075).
public struct BindingConflict: Equatable, Sendable {
    public let first: KeyBinding
    public let second: KeyBinding
    public init(first: KeyBinding, second: KeyBinding) { self.first = first; self.second = second }
}

/// Detects collisions after uppercase normalization, using the same validation as menus (B-075).
public enum BindingConflictDetector {
    public static func conflicts(in bindings: [KeyBinding], context: CommandContext) -> [BindingConflict] {
        let active = bindings.filter { !$0.key.isEmpty && CommandValidation.state(for: $0.command, in: context) == .enabled }
        var result: [BindingConflict] = []
        for (index, first) in active.enumerated() {
            for second in active.dropFirst(index + 1) where first.command != second.command {
                if first.key.lowercased() == second.key.lowercased() && first.effectiveModifiers == second.effectiveModifiers {
                    result.append(BindingConflict(first: first, second: second))
                }
            }
        }
        return result
    }
}
