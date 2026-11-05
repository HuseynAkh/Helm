// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

/// Search entry preserves the legacy placeholder; host receives each edit (F-043).
public struct SearchBarView: View {
    @Binding private var model: SearchBarModel
    private let cancel: () -> Void
    public init(model: Binding<SearchBarModel>, cancel: @escaping () -> Void) {
        _model = model; self.cancel = cancel
    }
    public var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                TextField("Search files and folders", text: $model.text)
                    .accessibilityLabel("Search files and folders")
                if model.status == .gathering { ProgressView().controlSize(.small) }
                Button("Cancel", action: cancel)
            }
            SearchScopeBar(model: $model)
            if model.scopeUnavailable { Text("This folder is unavailable").foregroundStyle(.secondary) }
            if let message = model.status.message { Text(message).foregroundStyle(.secondary) }
            if model.truncated { Text("Result limit reached. Refine your search.").foregroundStyle(.secondary) }
        }
        // MAC-VERIFY: Host must route Cmd+F focus/select-all and preserve IME composition.
    }
}

/// Scope and kind criteria are values; selecting them performs no search I/O (F-043/F-044).
public struct SearchScopeBar: View {
    @Binding private var model: SearchBarModel
    public init(model: Binding<SearchBarModel>) { _model = model }
    public var body: some View {
        VStack(alignment: .leading) {
            Picker("Search", selection: $model.scope) {
                ForEach(SearchScopeChoice.allCases, id: \.self) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }.pickerStyle(.segmented)
            HStack {
                kindChip("Any Kind", kind: nil)
                kindChip("Folder", kind: .directory)
                kindChip("File", kind: .regular)
            }
        }
    }
    private func kindChip(_ title: String, kind: FileEntryKind?) -> some View {
        Button { model.kind = kind } label: {
            Label(title, systemImage: model.kind == kind ? "checkmark.circle.fill" : "circle")
        }
        .accessibilityValue(model.kind == kind ? "Selected" : "Not selected")
    }
}

/// Leaf cell for the host's Location column; preserves full enclosing path (F-043, M-24).
public struct SearchLocationColumnView: View {
    private let model: SearchLocationColumnModel
    public init(model: SearchLocationColumnModel) { self.model = model }
    public var body: some View {
        Text(model.text).lineLimit(1).truncationMode(.middle)
            .help(model.text).accessibilityLabel(model.accessibilityLabel)
    }
}
