#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import HelmCore

/// Properties: the item's icon, name and kind, then what it is and where, then who can do what with it, in the
/// grouped rows Helm's Settings use. Values can be selected and copied. For an item the person owns, who can do what
/// is changed here, as in Finder's Sharing & Permissions and Nautilus's Permissions page. Nothing else here changes
/// the item.
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
                    ForEach(model.permissionRows, id: \.label) { item in
                        row(item, model: model)
                        // Nautilus's checkbox, after the three classes of user it's about.
                        if item.label == "Others", let on = model.allowsExecuting { executeRow(on, model: model) }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    if let footer = model.permissionsFooter {
                        Text(footer).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                    if !row.value.isEmpty {
                        Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                            .lineLimit(row.reveals ? 2 : nil).truncationMode(.middle)
                    }
                    if let control = row.control {
                        AccessPopUp(label: row.label, control: control) { access in
                            session.choose(access, for: control.subject)
                        }
                        .fixedSize()
                        .disabled(!model.permissionControlsEnabled)
                    }
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

    /// "Allow executing file as program", as Nautilus words it, for a file of the person's own.
    private func executeRow(_ on: Bool, model: PropertiesViewModel) -> some View {
        LabeledContent("Execute") {
            Toggle("Allow executing file as program", isOn: Binding(get: { on }, set: { session.allowExecuting($0) }))
                .toggleStyle(.checkbox)
                .disabled(!model.permissionControlsEnabled || !model.canToggleExecuting)
        }
    }
}

/// Finder's privilege pop-up: Read & Write, Read only and No access. While the class's bits match none of them it
/// shows Custom, which can't be chosen. Choosing what it already shows changes nothing. It's off where the view is
/// disabled.
private struct AccessPopUp: NSViewRepresentable {
    let label: String
    let control: PermissionControl
    let choose: (FinderAccess) -> Void

    func makeCoordinator() -> Picked { Picked() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Picked.picked(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.choose = choose
        button.removeAllItems()
        for access in FinderAccess.allCases {
            let item = NSMenuItem(title: access.title, action: nil, keyEquivalent: "")
            item.representedObject = access.rawValue
            button.menu?.addItem(item)
        }
        if let choice = control.choice, let index = FinderAccess.allCases.firstIndex(of: choice) {
            button.selectItem(at: index)
        } else {
            button.menu?.addItem(.separator())
            let custom = NSMenuItem(title: control.title, action: nil, keyEquivalent: "")
            custom.isEnabled = false
            button.menu?.addItem(custom)
            button.select(custom)
        }
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel("\(label) access")
    }

    final class Picked: NSObject {
        var choose: ((FinderAccess) -> Void)?
        @objc func picked(_ sender: NSPopUpButton) {
            guard let raw = sender.selectedItem?.representedObject as? String, let access = FinderAccess(rawValue: raw) else { return }
            choose?(access)
        }
    }
}
#endif
