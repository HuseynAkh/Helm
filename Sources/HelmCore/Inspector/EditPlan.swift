// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-050 reversible attribute intent. Revalidate `original` before writing.
public struct InspectorAttributeChange: Equatable, Sendable {
    public let original: InspectorAttribute
    public let proposed: InspectorAttribute
    public let applyToEnclosedItems: Bool
    public init(original: InspectorAttribute, proposed: InspectorAttribute, applyToEnclosedItems: Bool = false) {
        self.original = original; self.proposed = proposed
        self.applyToEnclosedItems = applyToEnclosedItems
    }
}

/// F-050 edits retain original identity even when a rename is planned (B-009).
public struct InspectorItemEdit: Equatable, Sendable {
    public let item: InspectorItem
    public let changes: [InspectorAttributeChange]
    public init(item: InspectorItem, changes: [InspectorAttributeChange]) {
        self.item = item; self.changes = changes
    }
}

/// Pure F-050 plan: adapters must recheck ownership, collisions, locks and stale metadata.
public struct EditPlan: Equatable, Sendable {
    public let items: [InspectorItemEdit]
    public init(items: [InspectorItemEdit]) { self.items = items }
    public var isEmpty: Bool { items.isEmpty }
}

/// F-050 validation blocks the plan instead of silently skipping selected items.
public enum InspectorValidationError: Error, Equatable, Sendable {
    case noSelection
    case unsupported(ItemID, InspectorField)
    case invalidName, multipleItemRename, extensionConfirmationRequired
    case invalidTag, invalidComment, invalidApplication, invalidPermissions
    case locked(ItemID)
    case recursivePermissionsRequireDirectory
}
