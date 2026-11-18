#if os(macOS)
import Foundation
import SwiftUI
import HelmCore

/// Properties: the item's icon, name and kind, then what it is and where, then who can do what with it, in the
/// grouped rows Helm's Settings use. Values can be selected and copied. Nothing here changes the item.
struct PropertiesView: View {
    static let width: CGFloat = 440
    @ObservedObject var session: PropertiesSession
    let icon: Image
    let reveal: ([URL]) -> Void

    var body: some View {
        let model = session.model
        Form {
            Section {
                HStack(spacing: 14) {
                    icon.resizable().scaledToFit().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.title).font(.title3.weight(.semibold)).lineLimit(3).textSelection(.enabled)
                        Text(model.kind).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            Section {
                ForEach(model.generalRows, id: \.label) { row($0, model: model) }
            }
            if !model.permissionRows.isEmpty {
                Section {
                    ForEach(model.permissionRows, id: \.label) { row($0, model: model) }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Shown as macOS keeps them. Helm doesn’t change them here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: Self.width, idealWidth: Self.width, minHeight: 320)
    }

    private func row(_ row: PropertiesRow, model: PropertiesViewModel) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    if row.isWorking { ProgressView().controlSize(.small) }
                    Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                        .lineLimit(row.reveals ? 2 : nil).truncationMode(.middle)
                    if row.reveals {
                        Button { reveal(model.entries.map(\.url)) } label: { Image(systemName: "arrow.right.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Show in Enclosing Folder")
                            .accessibilityLabel("Show in Enclosing Folder")
                    }
                }
                if let note = row.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } label: {
            Text(row.label)
        }
    }
}
#endif
