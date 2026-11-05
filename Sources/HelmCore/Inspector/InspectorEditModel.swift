// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-050 Inspector draft retains originals until an adapter reports success.
/// Selection changes create a new model; resetting discards drafts without I/O.
public struct InspectorEditModel: Equatable, Sendable {
    public let originals: [InspectorItem]
    public private(set) var pending: [InspectorField: InspectorAttribute]
    private var permissionRows: PermissionsModel
    /// F-050 rows project the effective draft; subsequent row edits modify a whole-mode draft.
    public var permissions: PermissionsModel {
        get {
            var rows = permissionRows
            if case .permissions(let mode) = pending[.permissions] { rows.wholeMode = mode }
            return rows
        }
        set {
            permissionRows = newValue
            permissionRows.wholeMode = nil
            pending.removeValue(forKey: .permissions)
            if let mode = newValue.wholeMode { set(.permissions(mode)) }
        }
    }
    public var applyPermissionsToEnclosedItems: Bool {
        get { permissions.applyToEnclosedItems }
        set { permissions.applyToEnclosedItems = newValue }
    }

    public init(items: [InspectorItem]) {
        var seen: Set<ItemID> = []
        originals = items.filter { seen.insert($0.id).inserted }
        pending = [:]
        permissionRows = PermissionsModel(modes: originals.compactMap { item in
            if case .permissions(let mode) = item.attributes[.permissions] { return mode }
            return nil
        })
        permissionRows.metadataComplete = permissionRows.originalModes.count == originals.count
    }
    public func value(for field: InspectorField) -> InspectorValue<InspectorAttribute> {
        if let edit = pending[field] { return .value(edit) }
        let values: [InspectorAttribute] = originals.compactMap { item in
            if field == .permissions, case .permissions(let mode) = item.attributes[field] {
                return .permissions(permissions.applying(to: mode))
            }
            return item.attributes[field]
        }
        guard values.count == originals.count else { return .unavailable }
        return InspectorValue(values: values)
    }
    public func canEdit(_ field: InspectorField) -> Bool {
        !originals.isEmpty && (field != .name || originals.count == 1) && originals.allSatisfy {
            $0.editableFields.contains(field) && $0.attributes[field] != nil
        }
    }
    /// Invalid drafts remain visible for correction; plan construction validates atomically.
    public mutating func set(_ attribute: InspectorAttribute) {
        let normalized: InspectorAttribute
        if case .name(let raw) = attribute, case .success(let name) = FileNameValidator.validate(raw) {
            normalized = .name(name.value)
        } else { normalized = attribute }
        if normalized.field == .permissions {
            let recursive = permissionRows.applyToEnclosedItems
            permissionRows.reset()
            permissionRows.applyToEnclosedItems = recursive
        }
        if originals.allSatisfy({ $0.attributes[normalized.field] == normalized }) {
            pending.removeValue(forKey: normalized.field)
        } else { pending[normalized.field] = normalized }
    }
    public mutating func reset(_ field: InspectorField) {
        pending.removeValue(forKey: field)
        if field == .permissions { permissions.reset() }
    }
    public mutating func reset() { pending = [:]; permissions.reset() }
    public var isDirty: Bool { !pending.isEmpty || permissions.isDirty }

    /// No execution occurs. Extension confirmation applies only to this exact draft.
    /// Changes are ordered unlock, attributes, rename, relock for future executor wiring.
    public func makePlan(confirmExtensionChange: Bool = false) throws -> EditPlan {
        guard !originals.isEmpty else { throw InspectorValidationError.noSelection }
        if pending[.name] != nil && originals.count != 1 { throw InspectorValidationError.multipleItemRename }
        if applyPermissionsToEnclosedItems && originals.contains(where: { !$0.isDirectory }) {
            throw InspectorValidationError.recursivePermissionsRequireDirectory
        }
        var planned: [InspectorItemEdit] = []
        for item in originals {
            var changes: [InspectorAttributeChange] = []
            let fields: [InspectorField] = [.locked, .hidden, .hiddenExtension, .tags, .comment,
                                            .defaultApplication, .permissions, .name]
            for field in fields {
                let recursive = field == .permissions && applyPermissionsToEnclosedItems
                var proposal = pending[field]
                if field == .permissions && permissions.isDirty && proposal == nil,
                   case .permissions(let mode) = item.attributes[field] {
                    proposal = .permissions(permissions.applying(to: mode))
                }
                guard let proposed = proposal else {
                    if field == .permissions && permissions.isDirty { throw InspectorValidationError.unsupported(item.id, field) }
                    continue
                }
                guard let original = item.attributes[field], item.editableFields.contains(field) else {
                    throw InspectorValidationError.unsupported(item.id, field)
                }
                try validate(proposed, original: original, item: item, confirmExtensionChange: confirmExtensionChange)
                if proposed != original || recursive {
                    changes.append(InspectorAttributeChange(original: original, proposed: proposed,
                                                            applyToEnclosedItems: recursive))
                }
            }
            if item.attributes[.locked] == .locked(true),
               changes.contains(where: { $0.proposed.field != .locked }), pending[.locked] != .locked(false) {
                throw InspectorValidationError.locked(item.id)
            }
            // Setting the lock is last; clearing it remains first.
            if let index = changes.firstIndex(where: { $0.proposed == .locked(true) }) {
                changes.append(changes.remove(at: index))
            }
            if !changes.isEmpty { planned.append(InspectorItemEdit(item: item, changes: changes)) }
        }
        return EditPlan(items: planned)
    }

    private func validate(_ proposed: InspectorAttribute, original: InspectorAttribute,
                          item: InspectorItem, confirmExtensionChange: Bool) throws {
        switch proposed {
        case .name(let name):
            guard case .success = FileNameValidator.validate(name) else { throw InspectorValidationError.invalidName }
            if case .name(let old) = original, !item.isDirectory,
               (old as NSString).pathExtension != (name as NSString).pathExtension, !confirmExtensionChange {
                throw InspectorValidationError.extensionConfirmationRequired
            }
        case .tags(let tags):
            if tags.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.contains("\0") || $0.contains("\n") }) || Set(tags).count != tags.count {
                throw InspectorValidationError.invalidTag
            }
        case .comment(let comment):
            if comment.contains("\0") { throw InspectorValidationError.invalidComment }
        case .defaultApplication(let url):
            if let url = url, !url.isFileURL || !url.path.hasPrefix("/") || url.pathExtension.lowercased() != "app" {
                throw InspectorValidationError.invalidApplication
            }
        case .permissions(let bits):
            if bits & ~UInt16(0o7777) != 0 { throw InspectorValidationError.invalidPermissions }
        case .locked, .hidden, .hiddenExtension: break
        }
    }
}
