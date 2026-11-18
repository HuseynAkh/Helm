#if os(macOS)
import AppKit
import HelmCore
import HelmOperations

/// Changes to an item's permissions from a Properties window this window opened. Each is one of this window's changes,
/// in its turn and in its history, so Edit › Undo, here or in the Properties window, puts the mode back.
extension BrowserWindowController {
    /// Changes `item`'s mode from `before` to `after`. Answers what to say when it didn't simply happen.
    func changePermissions(of item: URL, identity: FileObjectIdentity, from before: UInt16, to after: UInt16) async -> String? {
        // As Undo is: while this window's work is under way the change is turned away, not left waiting behind it.
        guard !isRunningOperations else { return Self.busyMessage }
        let history = history, operations = dependencies.operations
        return await enqueueOperationAwaiting { [weak self] in
            let outcome = await operations.changePermissions(of: item, identity: identity, from: before, to: after, history: history)
            await self?.refreshHistory()
            switch outcome {
            case .success:
                // A file that runs as a program may now be listed as another kind.
                self?.refreshTabs(touching: [item.deletingLastPathComponent()], selecting: [])
                return nil
            case .failure(.busy): return Self.busyMessage
            case .failure(.cancelled): return nil
            case .failure(.message(let message)): return message
            }
        }
    }
}

/// Changing permissions in Properties windows, for tests and fixture runs.
extension BrowserWindowController {
    private var newestProperties: PropertiesSession? { propertiesWindows.last?.session }
    /// The newest Properties window's line under the permissions.
    public var propertiesFooterForTesting: String? { newestProperties?.model.permissionsFooter }
    /// What the pop-up beside a row reads, such as "Read only" or "Custom", or nil when it has none.
    public func propertiesAccessForTesting(_ label: String) -> String? {
        newestProperties?.model.permissionRows.first { $0.label == label }?.control?.title
    }
    /// Whether "Allow executing file as program" is on, or nil when it isn't shown.
    public var propertiesExecuteForTesting: Bool? { newestProperties?.model.allowsExecuting }
    /// Whether the permission controls can be used.
    public var propertiesControlsEnabledForTesting: Bool { newestProperties?.model.permissionControlsEnabled ?? false }
    /// Chooses an item of a row's pop-up by its title, as a click on it does, and waits for the change. False when the
    /// row has no pop-up, or no such item, or the choice changed nothing.
    public func propertiesChooseForTesting(_ label: String, _ title: String) async -> Bool {
        guard let session = newestProperties, let access = FinderAccess.allCases.first(where: { $0.title == title }),
              let control = session.model.permissionRows.first(where: { $0.label == label })?.control,
              let mode = session.model.mode(choosing: access, for: control.subject),
              let change = session.changeMode(to: mode) else { return false }
        await change.value
        return true
    }
    /// Turns "Allow executing file as program" on or off, as a click on it does, and waits for the change.
    public func propertiesAllowExecutingForTesting(_ on: Bool) async -> Bool {
        guard let session = newestProperties, let mode = session.model.mode(allowingExecution: on),
              let change = session.changeMode(to: mode) else { return false }
        await change.value
        return true
    }
    /// Sends Edit › Undo, or Redo, to the newest Properties window as its menu item does, from its first responder up.
    /// False when nothing there answers it.
    public func propertiesUndoForTesting(redo: Bool) -> Bool {
        guard let window = propertiesWindows.last?.window else { return false }
        let action = redo ? #selector(BrowserWindowController.redo(_:)) : #selector(BrowserWindowController.undo(_:))
        return (window.firstResponder ?? window).tryToPerform(action, with: nil)
    }
    /// What Edit › Undo, or Redo, reads while the newest Properties window is in front, and whether it can be chosen.
    public func propertiesUndoItemForTesting(redo: Bool) -> (title: String, enabled: Bool)? {
        guard let window = propertiesWindows.last?.window else { return nil }
        let action = redo ? #selector(BrowserWindowController.redo(_:)) : #selector(BrowserWindowController.undo(_:))
        let item = NSMenuItem(title: redo ? "Redo" : "Undo", action: action, keyEquivalent: "")
        let enabled = window.validateMenuItem(item)
        return (item.title, enabled)
    }
}
#endif
