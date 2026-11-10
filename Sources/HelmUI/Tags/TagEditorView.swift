// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

/// Popover drafts tag edits without writing file metadata (F-029, M18).
public struct TagEditorView: View {
    @Binding private var model: TagEditorModel
    private let apply: (TagSet) -> Void
    private let cancel: () -> Void
    private let errorMessage: String?
    public init(model: Binding<TagEditorModel>, errorMessage: String? = nil,
                apply: @escaping (TagSet) -> Void, cancel: @escaping () -> Void) {
        _model = model; self.errorMessage = errorMessage; self.apply = apply; self.cancel = cancel
    }
    public var body: some View {
        VStack(alignment: .leading) {
            Text("Tags").font(.headline)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(Array(model.tags.tags.enumerated()), id: \.offset) { _, tag in
                        HStack {
                            TagDotView(tag: tag)
                            Text(tag.name)
                            Spacer()
                            Button { model.remove(tag) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("Remove tag \(tag.name)")
                        }
                    }
                }
            }.frame(maxHeight: 180)
            TextField("Tag name", text: $model.name).onSubmit { model.add() }
            Picker("Color", selection: $model.color) {
                ForEach(FinderTagColor.allCases, id: \.self) { Text(TagEditorModel.label($0)).tag($0) }
            }
            Button("Add") { model.add() }.disabled(!model.canAdd)
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { apply(model.tags) }
            }
        }
        // MAC-VERIFY: Return adds a tag; Escape cancels without invoking Apply.
        .padding().frame(minWidth: 280)
    }
}
