// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

/// F-055's three modes, tokens and 20-row preview; host executes and dismisses (B-117).
public struct BatchRenameSheet: View {
    @Binding private var model: BatchRenameViewModel
    @State private var displayed: BatchRenameEvaluation?
    private let rename: (BatchRenamePlan) -> Void
    private let cancel: () -> Void
    public init(model: Binding<BatchRenameViewModel>, rename: @escaping (BatchRenamePlan) -> Void,
                cancel: @escaping () -> Void) {
        _model = model; self.rename = rename; self.cancel = cancel
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename \(model.items.count) Items").font(.headline)
            Picker("Mode", selection: $model.mode) {
                ForEach(BatchRenameViewModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            controls
            Divider()
            Text("Preview").font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    // Index identity also tolerates invalid duplicate source inputs.
                    ForEach(Array((displayed?.revision == model.revision ? displayed?.preview ?? [] : []).enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.source.lastPathComponent).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            Text(row.proposedName)
                        }.lineLimit(1).font(.system(.body, design: .monospaced))
                            .help(row.source.path)
                    }
                    if model.items.count > 20 {
                        Text("... and \(model.items.count - 20) more").foregroundStyle(.tertiary)
                    }
                    ForEach(Array((displayed?.revision == model.revision ? displayed?.messages ?? [] : ["Updating preview…"]).enumerated()), id: \.offset) { _, message in
                        Text(message).foregroundStyle(.red).font(.caption)
                    }
                }
            }.frame(maxHeight: 200)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Rename") {
                    if let plan = displayed?.executablePlan(for: model.revision) { rename(plan) }
                }.keyboardShortcut(.defaultAction).disabled(displayed?.executablePlan(for: model.revision) == nil)
            }
        }.padding(20).frame(width: 500, height: 450)
            .task(id: model.revision) {
                let snapshot = model
                do { try await Task.sleep(nanoseconds: 150_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                let evaluation = await Task.detached(priority: .userInitiated) {
                    snapshot.evaluation
                }.value
                guard !Task.isCancelled, evaluation.revision == model.revision else { return }
                displayed = evaluation
            }
    }
    @ViewBuilder private var controls: some View {
        switch model.mode {
        case .addText:
            field("Prepend:", "Text to add before name", $model.prepend)
            field("Append:", "Text to add after name", $model.append)
        case .findReplace:
            field("Find:", "Text to find", $model.find)
            field("Replace:", "Replacement text", $model.replacement)
        case .template:
            field("Template:", "[Original Name]-[Counter]", $model.template)
            field("Start at:", "1", $model.counterStart)
            Text("Tokens: [Original Name], [Counter], [Date]").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func field(_ label: String, _ placeholder: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .trailing)
            TextField(placeholder, text: value).accessibilityLabel(label)
        }
    }
}
