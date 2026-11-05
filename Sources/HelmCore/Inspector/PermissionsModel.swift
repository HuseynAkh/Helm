// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-050 POSIX rows; ACLs and effective access are not inferred from these bits.
public enum PermissionSubject: Int, CaseIterable, Sendable, Codable {
    case owner = 6, group = 3, everyone = 0
}

/// Preserves F-050 read/write/execute independently of Finder's read/write label.
public struct PermissionAccess: Equatable, Sendable, Codable {
    public var read: Bool
    public var write: Bool
    public var execute: Bool
    public init(read: Bool, write: Bool, execute: Bool) {
        self.read = read; self.write = write; self.execute = execute
    }
    public init(bits: UInt16) {
        self.init(read: bits & 4 != 0, write: bits & 2 != 0, execute: bits & 1 != 0)
    }
    public var bits: UInt16 { (read ? 4 : 0) | (write ? 2 : 0) | (execute ? 1 : 0) }
    public var finderLabel: String {
        switch (read, write) {
        case (true, true): return "Read & Write"
        case (true, false): return "Read only"
        case (false, true): return "Write only"
        case (false, false): return "No Access"
        }
    }
}

/// F-050 edits preserve special bits and untouched rows across a selection.
/// Recursive intent is a plan flag only; this type never enumerates files.
public struct PermissionsModel: Equatable, Sendable {
    public let originalModes: [UInt16]
    public private(set) var edits: [PermissionSubject: PermissionAccess]
    public var applyToEnclosedItems: Bool
    public init(modes: [UInt16], applyToEnclosedItems: Bool = false) {
        originalModes = modes; edits = [:]; self.applyToEnclosedItems = applyToEnclosedItems
    }
    public func row(_ subject: PermissionSubject) -> InspectorValue<PermissionAccess> {
        InspectorValue(values: originalModes.map { PermissionAccess(bits: applying(to: $0) >> subject.rawValue) })
    }
    public mutating func set(_ access: PermissionAccess, for subject: PermissionSubject) {
        if originalModes.allSatisfy({ PermissionAccess(bits: $0 >> subject.rawValue) == access }) {
            edits.removeValue(forKey: subject)
        } else { edits[subject] = access }
    }
    public mutating func reset() { edits = [:]; applyToEnclosedItems = false }
    public func applying(to mode: UInt16) -> UInt16 {
        edits.reduce(mode) { result, edit in
            let shift = edit.key.rawValue
            return (result & ~(UInt16(7) << shift)) | (edit.value.bits << shift)
        }
    }
    public var isDirty: Bool { !edits.isEmpty || applyToEnclosedItems }
}
