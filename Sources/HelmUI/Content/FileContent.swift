#if os(macOS)
import AppKit
import HelmCore

/// What the list and grid ask of their window. They hold no file state of their own (principle 1).
@MainActor protocol FileContentHost: AnyObject {
    var icons: IconCache { get }
    var gridIconSize: Int { get }
    var fileTextSize: CGFloat { get }
    var starred: Set<ItemID> { get }
    func contentSelectionChanged(_ ids: Set<ItemID>)
    func contentOpen(_ entries: [FileEntry], newTab: Bool)
    func contentMenu(for entries: [FileEntry]) -> NSMenu?
    func contentRenameFinished(_ entry: FileEntry, newName: String?)
    func contentSetSort(_ sort: ItemSort)
    func contentExpand(_ id: ItemID)
    func contentCollapse(_ id: ItemID)
    /// The operation for a drop on `entry` (a folder or app), or on the folder on show when nil.
    func contentDropOperation(_ info: NSDraggingInfo, onto entry: FileEntry?) -> NSDragOperation
    func contentPerformDrop(_ info: NSDraggingInfo, onto entry: FileEntry?) -> Bool
    /// The drag left the view or finished, so a folder waiting to spring open shouldn't.
    func contentDragEnded()
    func contentKeyDown(_ event: NSEvent) -> Bool
    func contentActivated()
}

/// A way of showing one tab's files.
@MainActor protocol FileContentPresenting: NSViewController {
    var host: FileContentHost? { get set }
    func render(_ tab: TabState, force: Bool)
    func beginRename(_ entry: FileEntry)
    func focusContent()
    /// The view that takes this content's keys.
    var keyResponder: NSResponder? { get }
    /// The view behind an item, for Quick Look's zoom. Nil if it's scrolled away.
    func screenFrame(of id: ItemID) -> NSRect?
    /// The image an item shows now, so Quick Look zooms out of the real picture.
    func image(of id: ItemID) -> NSImage?
}

extension FileEntry {
    /// The name as shown. Applications drop `.app`, as they do everywhere else on a Mac. The file keeps its real name.
    var displayName: String {
        kind == .package && name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
    /// What the kind column says.
    var kindText: String {
        if let description = localizedKindDescription { return description }
        switch kind {
        case .directory: return "Folder"
        case .symlinkToDirectory, .symlinkToFile, .danglingSymlink: return "Alias"
        case .alias: return "Alias"
        case .package: return "Package"
        default: return "Document"
        }
    }
    var sizeText: String {
        if kind == .directory || kind == .symlinkToDirectory { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    var dateText: String {
        modificationDate == .distantPast ? "—" : DateFormatter.helmList.string(from: modificationDate)
    }
}

extension DateFormatter {
    static let helmList: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

/// Reference identity for AppKit, one per ItemID, so rows and expansion survive a reload.
final class ItemBox: NSObject {
    let id: ItemID
    init(_ id: ItemID) { self.id = id }
}

/// Keeps the rename field's end-of-editing rules in one place for both views.
@MainActor final class RenameEditor: NSObject, NSTextFieldDelegate {
    private let entry: FileEntry
    private let finish: (FileEntry, String?) -> Void
    private var cancelled = false
    private var finished = false
    weak var field: NSTextField?
    init(entry: FileEntry, field: NSTextField, finish: @escaping (FileEntry, String?) -> Void) {
        self.entry = entry; self.field = field; self.finish = finish
    }
    func begin(in window: NSWindow?) {
        guard let field else { return }
        field.isEditable = true; field.isSelectable = true; field.delegate = self
        field.drawsBackground = true; field.backgroundColor = .textBackgroundColor
        window?.makeFirstResponder(field)
        var model = InlineRenameModel()
        _ = model.begin(entry)
        field.currentEditor()?.selectedRange = model.editing?.selectedRange ?? NSRange(location: 0, length: (entry.name as NSString).length)
    }
    /// Clicking away commits, which is what Finder and Nautilus both do (OK2-12).
    func controlTextDidEndEditing(_ notification: Notification) { end() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelled = true
            control.abortEditing()
            end()
            return true
        }
        return false
    }
    private func end() {
        guard !finished, let field else { return }
        finished = true
        let text = field.stringValue
        field.isEditable = false; field.isSelectable = false; field.delegate = nil
        field.drawsBackground = false
        field.stringValue = entry.name
        finish(entry, cancelled ? nil : text)
    }
}
#endif
