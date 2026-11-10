// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
#if canImport(AppKit)
import AppKit
import SwiftUI
import HelmCore

/// F-054 inline editing delegates validation, UTF-16 stem ranges and key intent to Core (B-046/B-066).
/// The operation owner completes requests and starts Tab's next session only after success.
public struct InlineRenameField: View {
    @Binding private var model: InlineRenameModel
    private let visibleOrder: [ItemID]
    private let submit: (InlineRenameRequest) -> Void
    public init(model: Binding<InlineRenameModel>, visibleOrder: [ItemID],
                submit: @escaping (InlineRenameRequest) -> Void) {
        self._model = model; self.visibleOrder = visibleOrder; self.submit = submit
    }
    public var body: some View {
        Group {
            if let session = model.editing {
                RenameTextField(session: session, pending: model.pending != nil,
                    edit: { text in model.edit(text, session: session.token) },
                    key: { key in
                        if let request = model.handle(key, session: session.token, visibleOrder: visibleOrder) {
                            submit(request)
                        }
                    })
                .frame(minHeight: 22)
                .popover(isPresented: Binding(get: { model.editing?.error != nil }, set: { _ in }),
                         arrowEdge: .bottom) {
                    if let error = model.editing?.error {
                        Text(error.message).font(.callout).padding(10).frame(maxWidth: 280)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(error.message)
                    }
                }
            }
        }
    }
}

struct RenameTextField: NSViewRepresentable {
    let session: InlineRenameSession
    let pending: Bool
    let edit: (String) -> Void
    let key: (InlineRenameKey) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> RenameNativeField {
        let field = RenameNativeField()
        field.isBordered = true; field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13); field.isEditable = true; field.isSelectable = true
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Rename")
        return field
    }
    func updateNSView(_ field: RenameNativeField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != session.text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = session.text
        }
        field.toolTip = session.error?.message
        if field.sessionToken != session.token {
            field.sessionToken = session.token
            field.pendingSelection = session.selectedRange
            field.requestInitialFocus()
        }
    }
    static func dismantleNSView(_ field: RenameNativeField, coordinator: Coordinator) {
        field.delegate = nil; field.sessionToken = nil; field.pendingSelection = nil
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameTextField
        init(parent: RenameTextField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Composition remains local until committed; never validate an incomplete IME sequence.
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            if parent.pending { field.stringValue = parent.session.text; return }
            parent.edit(field.stringValue)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            let key: InlineRenameKey
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)): key = .escape
            case #selector(NSResponder.insertNewline(_:)): key = .returnKey
            case #selector(NSResponder.insertTab(_:)): key = .tab
            default: return false
            }
            parent.key(key)
            return true
        }
    }
}

final class RenameNativeField: NSTextField {
    var sessionToken: UInt64?
    var pendingSelection: NSRange?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestInitialFocus()
    }
    func requestInitialFocus() {
        guard let token = sessionToken, pendingSelection != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionToken == token, let range = self.pendingSelection,
                  let window = self.window, window.makeFirstResponder(self),
                  let editor = self.currentEditor() as? NSTextView else { return }
            let length: Int = editor.string.utf16.count
            let start: Int = min(max(0, range.location), length)
            editor.setSelectedRange(NSRange(location: start, length: min(max(0, range.length), length - start)))
            self.pendingSelection = nil
        }
    }
}
#endif
