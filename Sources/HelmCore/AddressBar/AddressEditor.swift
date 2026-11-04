import Foundation

/// Pure F-014–F-024 keyboard state machine, fixing stale-row Return and late replies (B-052).
public enum AddressEditor {
    public static func reduce(_ state: AddressEditorState, _ action: AddressEditorAction) -> (AddressEditorState, [AddressEditorEffect]) {
        var next: AddressEditorState = state
        var effects: [AddressEditorEffect] = []
        if action == .beginEditing {
            guard !next.isEditing else { return (state, []) }
            next.isEditing = true
            next.text = PathEntry.directoryText(next.currentDirectory)
            refresh(&next, effects: &effects)
            return (next, effects)
        }
        guard next.isEditing else {
            if case .showHiddenChanged(let value) = action { next.showHidden = value }
            return (next, [])
        }
        switch action {
        case .beginEditing: break
        case .textChanged(let text), .paste(let text):
            next.text = text
            refresh(&next, effects: &effects)
        case .caretChanged(let atEnd): next.caretAtEnd = atEnd
        case .showHiddenChanged(let value):
            next.showHidden = value
            refresh(&next, effects: &effects)
        case .completions(let generation, let rows):
            guard generation == next.generation, next.pendingCommit == nil else { return (state, []) }
            next.rows = rows; next.selectedIndex = rows.isEmpty ? nil : 0
            next.isPopupVisible = !rows.isEmpty; next.error = nil
        case .completionFailed(let generation, let message):
            guard generation == next.generation, next.pendingCommit == nil else { return (state, []) }
            clearRows(&next); next.error = message
        case .select(let index):
            next.selectedIndex = index.flatMap { next.rows.indices.contains($0) ? $0 : nil }
        case .arrowUp, .arrowDown:
            if next.isPopupVisible && !next.rows.isEmpty {
                let delta: Int = action == .arrowUp ? -1 : 1
                next.selectedIndex = min(max((next.selectedIndex ?? 0) + delta, 0), next.rows.count - 1)
            }
        case .tab:
            if let row = next.selectedRow { accept(row, state: &next, effects: &effects) }
            else { refresh(&next, effects: &effects) }
        case .acceptSelection:
            if let row = next.selectedRow { accept(row, state: &next, effects: &effects) }
        case .arrowRight:
            if next.ghostSuffix != nil, let row = next.selectedRow {
                accept(row, state: &next, effects: &effects)
            }
        case .backtab: break // Consumed by the UI; focus remains in the editor.
        case .returnKey:
            if !next.text.hasSuffix("/"), let row = next.selectedRow {
                next.text = PathCompletionEngine.acceptedText(row: row, typed: next.text, home: next.home)
            }
            invalidate(&next, effects: &effects)
            if let url = PathEntry.commitURL(text: next.text, currentDirectory: next.currentDirectory, home: next.home) {
                next.pendingCommit = url
                effects.append(.validate(url, next.generation))
            } else { invalid(&next, effects: &effects) }
        case .escape:
            if next.isPopupVisible { invalidate(&next, effects: &effects) }
            else { cancel(&next, effects: &effects) }
        case .cancel: cancel(&next, effects: &effects)
        case .validated(let generation, let url, let kind):
            guard generation == next.generation, next.pendingCommit == url else { return (state, []) }
            next.pendingCommit = nil
            if kind == .invalid { invalid(&next, effects: &effects) }
            else {
                next.isEditing = false
                next.error = nil
                effects.append(kind == .directory ? .navigate(url) : .openFile(url))
            }
        }
        return (next, effects)
    }

    private static func clearRows(_ state: inout AddressEditorState) {
        state.rows = []; state.selectedIndex = nil; state.isPopupVisible = false
    }

    private static func invalidate(_ state: inout AddressEditorState, effects: inout [AddressEditorEffect]) {
        state.generation = state.generation.next()
        state.pendingCommit = nil; state.error = nil
        clearRows(&state)
        effects.append(.cancelCompletions)
    }

    private static func refresh(_ state: inout AddressEditorState, effects: inout [AddressEditorEffect]) {
        invalidate(&state, effects: &effects)
        state.caretAtEnd = true
        if let request = PathCompletionEngine.request(for: state.text, currentDirectory: state.currentDirectory,
                                                       home: state.home, showHidden: state.showHidden, generation: state.generation) {
            effects.append(.requestCompletions(request))
        }
    }

    private static func accept(_ row: CompletionRow, state: inout AddressEditorState, effects: inout [AddressEditorEffect]) {
        state.text = PathCompletionEngine.acceptedText(row: row, typed: state.text, home: state.home)
        if row.isDirectory { refresh(&state, effects: &effects) }
        else { invalidate(&state, effects: &effects); state.caretAtEnd = true }
    }

    private static func cancel(_ state: inout AddressEditorState, effects: inout [AddressEditorEffect]) {
        invalidate(&state, effects: &effects)
        state.isEditing = false
        effects.append(.cancelled)
    }

    private static func invalid(_ state: inout AddressEditorState, effects: inout [AddressEditorEffect]) {
        state.error = "Invalid path or folder not accessible"
        effects.append(.invalidPathFeedback)
    }
}
