// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

/// Sheet drafts toolbar order; Apply returns a validated proposal (F-003/F-043, M24).
public struct ToolbarCustomizationView: View {
    @Binding private var model: ToolbarCustomizationModel
    @State private var dragSession: String = UUID().uuidString
    private let apply: ([HelmCore.ToolbarItem]) -> Void
    private let cancel: () -> Void
    public init(model: Binding<ToolbarCustomizationModel>, apply: @escaping ([HelmCore.ToolbarItem]) -> Void,
                cancel: @escaping () -> Void) {
        _model = model; self.apply = apply; self.cancel = cancel
    }
    public var body: some View {
        VStack(alignment: .leading) {
            Text("Customize Toolbar").font(.headline)
            Text("Drag items to reorder, or use Move Up and Move Down.")
            ScrollView {
                VStack {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        HStack {
                            Text(ToolbarCustomizationModel.label(item))
                            Spacer()
                            Button("Move Up") { model.move(from: index, to: index - 1) }.disabled(index == 0)
                            Button("Move Down") { model.move(from: index, to: index + 1) }
                                .disabled(index == model.items.count - 1)
                            Button("Remove") { model.remove(at: index) }
                                .accessibilityLabel("Remove \(ToolbarCustomizationModel.label(item))")
                        }
                        // MAC-VERIFY: macOS 14 String Transferable drag/drop inside hosted sheet.
                        .draggable("\(dragSession):\(index)")
                        .dropDestination(for: String.self) { payloads, _ in
                            guard payloads.count == 1, let payload = payloads.first,
                                  payload.hasPrefix(dragSession + ":"),
                                  let source = Int(payload.dropFirst(dragSession.count + 1)),
                                  model.items.indices.contains(source) else { return false }
                            model.move(from: source, to: index)
                            dragSession = UUID().uuidString
                            return true
                        }
                    }
                }
            }.frame(maxHeight: 260)
            Menu("Add Item") {
                ForEach(HelmCore.ToolbarItem.allCases, id: \.self) { item in
                    Button(ToolbarCustomizationModel.label(item)) { model.add(item) }
                        .disabled(item != .flexibleSpace && model.items.contains(item))
                }
            }
            Text("Cmd+L and Cmd+F stay reachable even when Path or Search is removed.")
            if !model.canApply {
                Text("Cannot apply: remove duplicate items and ensure Cmd+L and Cmd+F are available.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Restore Defaults") { model.restoreDefaults() }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply") { if model.canApply { apply(model.items) } }
                    .disabled(!model.canApply).keyboardShortcut(.defaultAction)
            }
        }.padding().frame(minWidth: 560)
    }
}
