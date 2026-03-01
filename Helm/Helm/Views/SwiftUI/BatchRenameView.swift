import SwiftUI

struct BatchRenameView: View {

    let items: [FileItem]
    let onRename: ([(URL, String)]) -> Void
    let onCancel: () -> Void

    @State private var mode: RenameMode = .appendPrepend
    @State private var prependText = ""
    @State private var appendText = ""
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var templateText = "[Original Name]-[Counter]"
    @State private var counterStart = 1

    enum RenameMode: String, CaseIterable {
        case appendPrepend = "Add Text"
        case findReplace = "Find & Replace"
        case template = "Template"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename \(items.count) Items")
                .font(.headline)

            Picker("Mode", selection: $mode) {
                ForEach(RenameMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .appendPrepend:
                appendPrependControls
            case .findReplace:
                findReplaceControls
            case .template:
                templateControls
            }

            Divider()

            // Preview
            Text("Preview")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(previewItems.prefix(20), id: \.0) { old, new in
                        HStack {
                            Text(old)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                            Text(new)
                                .foregroundStyle(old != new ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .font(.system(.body, design: .monospaced))
                    }

                    if items.count > 20 {
                        Text("... and \(items.count - 20) more")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxHeight: 200)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { performRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges)
            }
        }
        .padding(20)
        .frame(width: 500, height: 450)
    }

    // MARK: - Mode Controls

    private var appendPrependControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Prepend:")
                    .frame(width: 60, alignment: .trailing)
                TextField("Text to add before name", text: $prependText)
            }
            HStack {
                Text("Append:")
                    .frame(width: 60, alignment: .trailing)
                TextField("Text to add after name", text: $appendText)
            }
        }
    }

    private var findReplaceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Find:")
                    .frame(width: 60, alignment: .trailing)
                TextField("Text to find", text: $findText)
            }
            HStack {
                Text("Replace:")
                    .frame(width: 60, alignment: .trailing)
                TextField("Replacement text", text: $replaceText)
            }
        }
    }

    private var templateControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Template:")
                    .frame(width: 60, alignment: .trailing)
                TextField("[Original Name]-[Counter]", text: $templateText)
            }
            HStack {
                Text("Start at:")
                    .frame(width: 60, alignment: .trailing)
                TextField("1", value: $counterStart, format: .number)
                    .frame(width: 60)
            }
            Text("Tokens: [Original Name], [Counter], [Date]")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Preview

    private var previewItems: [(String, String)] {
        items.enumerated().map { index, item in
            let original = nameWithoutExtension(item.name)
            let ext = fileExtension(item.name)
            let newBase: String

            switch mode {
            case .appendPrepend:
                newBase = prependText + original + appendText
            case .findReplace:
                if findText.isEmpty {
                    newBase = original
                } else {
                    newBase = original.replacingOccurrences(of: findText, with: replaceText)
                }
            case .template:
                newBase = templateText
                    .replacingOccurrences(of: "[Original Name]", with: original)
                    .replacingOccurrences(of: "[Counter]", with: "\(counterStart + index)")
                    .replacingOccurrences(of: "[Date]", with: dateString())
            }

            let newName = ext.isEmpty ? newBase : "\(newBase).\(ext)"
            return (item.name, newName)
        }
    }

    private var hasChanges: Bool {
        previewItems.contains { $0.0 != $0.1 }
    }

    private func performRename() {
        let renames = previewItems.enumerated().compactMap { index, pair -> (URL, String)? in
            guard pair.0 != pair.1 else { return nil }
            return (items[index].url, pair.1)
        }
        onRename(renames)
    }

    private func nameWithoutExtension(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    private func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension
    }

    private func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
