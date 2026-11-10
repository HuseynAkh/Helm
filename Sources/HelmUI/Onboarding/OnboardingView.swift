#if os(macOS)
import AppKit
import HelmCore
import SwiftUI
import UniformTypeIdentifiers

/// The welcome window: Helm's icon, one line about it, a short checklist and two buttons. The guide is the same window
/// with only the Full Disk Access row, under a header that already names it.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    static let width: CGFloat = 540

    var body: some View {
        VStack(spacing: 0) {
            SetupHeader(mode: model.mode)
            VStack(spacing: 0) {
                if model.rows.isEmpty {
                    Text("Nothing to set up.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(16)
                }
                ForEach(Array(model.rows.enumerated()), id: \.element) { index, row in
                    if index > 0 { Divider().padding(.leading, model.mode == .setup ? 42 : 14) }
                    SetupRowView(model: model, row: row)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 24)
            Divider().opacity(0.6)
            SetupFooter(model: model)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Helm's own icon: the app's, which is the bundle's when Helm runs as an app.
@MainActor private var helmIcon: NSImage { NSApp.applicationIconImage ?? NSWorkspace.shared.icon(for: .applicationBundle) }

private struct SetupHeader: View {
    let mode: OnboardingModel.Mode
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: helmIcon).resizable().interpolation(.high).frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .accessibilityHidden(true)
            Text(mode == .guide ? "Full Disk Access" : "Welcome to Helm")
                .font(.system(size: 24, weight: .bold)).padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            // The one promise worth reading before Full Disk Access. The guide's row says what access gives.
            if mode == .setup {
                Text("Nothing leaves your Mac.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 48).padding(.top, 32)
    }
}

/// One row: a checkbox, a title and a line of detail, and on the right how it stands. A row that's already done has no
/// checkbox, only the check mark. In the guide, the header above already names the row, so it shows only its detail.
private struct SetupRowView: View {
    @ObservedObject var model: OnboardingModel
    let row: SetupRow

    var body: some View {
        let state = model.state(of: row)
        let box = model.hasCheckbox(row)
        let reason = model.unavailableReason(row)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if model.mode == .setup {
                    ZStack {
                        if box {
                            Toggle(row.title, isOn: Binding(get: { model.isChecked(row) }, set: { model.setChecked(row, $0) }))
                                .toggleStyle(.checkbox).labelsHidden()
                                .disabled(!model.canChoose || reason != nil)
                                .accessibilityHint(reason.map { row.detail + " " + $0 } ?? row.detail)
                        }
                    }
                    .frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if model.mode == .setup {
                        Text(row.title).font(.system(size: 13, weight: .semibold))
                    }
                    Text(row.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason {
                        Label(reason, systemImage: "info.circle")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Clicking the words ticks the box, as with any checkbox's label.
                .onTapGesture { if box && reason == nil { model.setChecked(row, !model.isChecked(row)) } }
                // VoiceOver hears the title and detail from the checkbox itself.
                .accessibilityHidden(box)
                SetupStatusView(state: state, row: row)
            }
            // A row without a checkbox reads as one line: its title (the guide's header has it), detail and how it stands.
            .accessibilityElement(children: box ? .contain : .combine)
            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, model.mode == .setup ? 28 : 0)
            }
            if row == .fullDiskAccess && model.showsAccessHelp {
                AccessHelpView(model: model).padding(.leading, model.mode == .setup ? 28 : 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// The right-hand side of a row: nothing yet, a spinner, Waiting, a check mark, or a warning.
private struct SetupStatusView: View {
    let state: SetupRowState
    let row: SetupRow
    var body: some View {
        Group {
            switch state {
            case .pending:
                Color.clear.frame(width: 18, height: 18).accessibilityHidden(true)
            case .working:
                ProgressView().controlSize(.small)
                    .accessibilityLabel(row == .moveToApplications ? "Copying to Applications" : "Setting up")
            case .waiting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Waiting for you to turn Helm on in System Settings")
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette).foregroundStyle(.white, Color.green)
                    .accessibilityLabel("Done")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15)).foregroundStyle(.orange)
                    .accessibilityLabel("Didn’t work")
            }
        }
        .frame(minWidth: 18, minHeight: 18, alignment: .trailing)
    }
}

/// Inside the Full Disk Access row while it waits: Helm's icon to drag into System Settings' list, and what to do there.
private struct AccessHelpView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        if model.isOutsideApp {
            Label("From Terminal, Helm uses Terminal’s permissions, so open Helm.app.", systemImage: "terminal")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 2) {
                    AppIconDragSource(appURL: model.permissions.appURL, image: helmIcon).frame(width: 52, height: 52)
                    Text("Helm").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.tertiary))
                .help("Drag into the Full Disk Access list")
                VStack(alignment: .leading, spacing: 6) {
                    // macOS's button name stays on one line: the spaces in it don't break.
                    Text("Turn Helm on in the list, or drag this icon in, then click Quit\u{00A0}&\u{00A0}Reopen.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    if model.permissions.isAdHocSigned {
                        // An ad hoc signed copy is new to macOS after each update, so a switch that's on may not count.
                        Text("If Helm is already on, remove it with − and add it again.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.rowOpensSettings {
                        Button("Open System Settings") { model.openFullDiskAccess() }.controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SetupFooter: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        HStack(spacing: 10) {
            if model.mode == .setup && model.secondaryTitle != nil {
                Text("Help › Set Up Helm… brings this back.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let secondary = model.secondaryTitle {
                Button(secondary) { model.notNow() }
                    .controlSize(.large).keyboardShortcut(.cancelAction)
            }
            Button(model.primaryTitle) { model.primary() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
}
#endif
