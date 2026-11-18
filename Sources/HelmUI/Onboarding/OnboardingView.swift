#if os(macOS)
import AppKit
import HelmAgent
import HelmCore
import SwiftUI
import UniformTypeIdentifiers

/// The welcome window. As the onboarding, one step at a time, every step the same size: an icon, a title and one line,
/// the step's own card, then the step indicator with Back and Continue. The guide is the same window with only the Full
/// Disk Access row, under a header that already names it. In AI mode the window shows the AI mode screen instead.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    static let width: CGFloat = 540
    /// Every step of the onboarding has this height below the title bar, so the window doesn't change size from one
    /// step to the next. The tallest step, AI mode with a provider that takes an address, fits it; anything taller
    /// scrolls in its card's place rather than being cut off.
    static let stepHeight: CGFloat = 560

    var body: some View {
        Group {
            switch model.mode {
            case .ai:
                if let ai = model.aiSetup { AIModeScreen(model: ai) }
            case .setup:
                OnboardingStepsView(model: model)
            case .guide:
                guide
            }
        }
        .onPreferenceChange(FooterFrame.self) { model.footerFrame = $0 }
    }

    private var guide: some View {
        VStack(spacing: 0) {
            SetupHeader(line: model.headerLine)
            VStack(spacing: 0) {
                ForEach(model.rows, id: \.self) { row in SetupRowView(model: model, row: row) }
            }
            .background(SetupCard.fill)
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 24)
            Divider().opacity(0.6)
            GuideFooter(model: model)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Where the footer's buttons are laid out, in the window's coordinates from its top left, so a check can see that they
/// sit inside the window.
struct FooterFrame: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {
    /// This row of buttons is the footer's.
    func reportsFooterFrame() -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: FooterFrame.self, value: proxy.frame(in: .global)) })
    }
}

/// Helm's own icon: the app's, which is the bundle's when Helm runs as an app.
@MainActor private var helmIcon: NSImage { NSApp.applicationIconImage ?? NSWorkspace.shared.icon(for: .applicationBundle) }

/// The rounded card every step's content sits in.
private enum SetupCard {
    @MainActor static var fill: some View { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)) }
}

/// The guide's header: Helm's icon and the name of its one row.
private struct SetupHeader: View {
    let line: String?
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: helmIcon).resizable().interpolation(.high).frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .accessibilityHidden(true)
            Text("Full Disk Access")
                .font(.system(size: 24, weight: .bold)).padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            if let line {
                Text(line)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 48).padding(.top, 32)
    }
}

// MARK: The onboarding's steps

/// One step: header, card, footer. The card sits under the header and the footer stays at the bottom, so Back and
/// Continue don't move from step to step.
private struct OnboardingStepsView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(step: model.step)
            ScrollView(.vertical) {
                StepCard(model: model)
                    .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider().opacity(0.6)
            StepFooter(model: model)
        }
        .frame(width: OnboardingView.width, height: OnboardingView.stepHeight)
    }
}

/// The step's icon, its title and its one line.
private struct StepHeader: View {
    let step: OnboardingStep
    var body: some View {
        VStack(spacing: 0) {
            StepIcon(step: step).frame(width: 72, height: 72).accessibilityHidden(true)
            Text(step.title)
                .font(.system(size: 24, weight: .bold)).padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            Text(step.subtitle)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 48).padding(.top, 32)
    }
}

/// Helm's icon on the welcome, the mark of AI mode on its step, and a symbol on the others.
private struct StepIcon: View {
    let step: OnboardingStep
    var body: some View {
        switch step {
        case .welcome:
            Image(nsImage: helmIcon).resizable().interpolation(.high)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        case .ai:
            Image(nsImage: SparkMark.image(size: 64, lit: true)).resizable().interpolation(.high).padding(4)
        case .access, .viewer, .done:
            Image(systemName: step.symbol)
                .font(.system(size: 44, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(step == .done ? Color.green : Color.accentColor)
        }
    }
}

/// What the step shows between its header and the footer.
private struct StepCard: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .access: AccessStep(model: model)
        case .viewer: card { SetupRowView(model: model, row: .fileViewer) }
        case .ai:
            if let ai = model.aiSetup {
                card { AIModeScreen(model: ai, embedded: true, continueRequests: model.aiContinueRequests) }
            }
        case .done: DoneStep(model: model)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SetupCard.fill)
    }
}

/// The welcome: the steps to come, so AI mode reads as part of setting Helm up, and the move to Applications when this
/// copy needs it.
private struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(spacing: 14) {
            let ahead = model.steps.filter { $0 != .welcome && $0 != .done }
            if !ahead.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ahead, id: \.self) { step in
                        HStack(spacing: 12) {
                            StepGlyph(step: step).frame(width: 22, height: 22)
                            Text(step.title).font(.system(size: 13, weight: .medium))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SetupCard.fill)
            }
            if model.rows.contains(.moveToApplications) {
                SetupRowView(model: model, row: .moveToApplications)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SetupCard.fill)
            }
        }
    }
}

/// A step's small mark in the welcome's list.
private struct StepGlyph: View {
    let step: OnboardingStep
    var body: some View {
        if step == .ai {
            Image(nsImage: SparkMark.image(size: 20, lit: true)).resizable().interpolation(.high)
        } else {
            Image(systemName: step.symbol).font(.system(size: 15)).foregroundStyle(Color.accentColor)
        }
    }
}

/// Full Disk Access: how it stands, the line about folder access, System Settings' button, and what macOS asks once
/// Helm is switched on. While it waits, Helm's icon to drag into the list.
private struct AccessStep: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        let state = model.state(of: .fullDiskAccess)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.statusLine).font(.system(size: 13, weight: .semibold))
                    if let note = model.folderNote(.fullDiskAccess) {
                        Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SetupStatusView(state: state, row: .fullDiskAccess)
            }
            .accessibilityElement(children: .combine)
            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isOutsideApp {
                AccessHelpView(model: model)
            } else if model.stepOpensSettings {
                if model.showsAccessHelp { AccessHelpView(model: model) }
                HStack(alignment: .center, spacing: 12) {
                    Button(OnboardingModel.openSettingsTitle) { model.openFullDiskAccess() }
                        .disabled(model.isWorking)
                    Text(OnboardingModel.reopenNote)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SetupCard.fill)
    }
}

/// Done: what's on and what's off, and the way back here.
private struct DoneStep: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        let lines = model.summary
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    if index > 0 { Divider().padding(.leading, 16) }
                    HStack(spacing: 10) {
                        Text(line.title).font(.system(size: 13))
                        Spacer(minLength: 8)
                        if line.on {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .symbolRenderingMode(.palette).foregroundStyle(.white, Color.green)
                                .accessibilityLabel("On")
                        } else {
                            Text("Off").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SetupCard.fill)
        }
    }
}

/// The step indicator, then Back, Not Now on the AI step, and Continue. Return is Continue; Escape is Not Now.
private struct StepFooter: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        HStack(spacing: 10) {
            StepDots(index: model.stepIndex, count: model.steps.count)
            Spacer(minLength: 8)
            if let back = model.backTitle {
                Button(back) { model.back() }
                    .controlSize(.large).disabled(model.isWorking)
            }
            if let secondary = model.secondaryTitle {
                Button(secondary) { model.notNow() }
                    .controlSize(.large).keyboardShortcut(.cancelAction).disabled(model.isWorking)
            }
            Button(model.primaryTitle) { model.continuePressed() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction).disabled(model.isWorking)
        }
        .reportsFooterFrame()
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
}

/// One dot per step, the step on show filled.
private struct StepDots: View {
    let index: Int
    let count: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<max(count, 1), id: \.self) { dot in
                Circle()
                    .fill(dot == index ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(count)")
    }
}

// MARK: Rows

/// One row: a checkbox, a title (and a line of detail where the header doesn't already say it), and on the right how it
/// stands. A row that's already done has no checkbox, only the check mark. In the guide, the header above already names
/// the row, so it shows only its detail.
private struct SetupRowView: View {
    @ObservedObject var model: OnboardingModel
    let row: SetupRow

    var body: some View {
        let state = model.state(of: row)
        let box = model.hasCheckbox(row)
        let reason = model.unavailableReason(row)
        let inSteps = model.mode == .setup
        // The file viewer step's header already says what the row does.
        let detail: String? = inSteps && row == .fileViewer ? nil : row.detail
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if inSteps {
                    ZStack {
                        if box {
                            Toggle(row.title, isOn: Binding(get: { model.isChecked(row) }, set: { model.setChecked(row, $0) }))
                                .toggleStyle(.checkbox).labelsHidden()
                                .disabled(!model.canChoose || reason != nil)
                                .accessibilityHint([detail, reason].compactMap { $0 }.joined(separator: " "))
                        }
                    }
                    .frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if inSteps {
                        Text(row.title).font(.system(size: 13, weight: .semibold))
                    }
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                    .padding(.leading, inSteps ? 28 : 0)
            }
            if row == .fullDiskAccess && model.showsAccessHelp {
                AccessHelpView(model: model)
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

/// While Full Disk Access waits: Helm's icon to drag into System Settings' list, and what to do there. The onboarding
/// says what macOS asks next on its own line, so here it's only the list.
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
                    Text(model.mode == .setup ? "Turn Helm on in the list, or drag this icon in."
                                              : "Turn Helm on in the list, or drag this icon in, then click Quit\u{00A0}&\u{00A0}Reopen.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    if model.permissions.isAdHocSigned {
                        // An ad hoc signed copy is new to macOS after each update, so a switch that's on may not count.
                        Text("If Helm is already on, remove it with − and add it again.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.rowOpensSettings {
                        Button(OnboardingModel.openSettingsTitle) { model.openFullDiskAccess() }.controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The guide's buttons: Not Now and Open System Settings, then Done.
private struct GuideFooter: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 8)
            if let secondary = model.secondaryTitle {
                Button(secondary) { model.notNow() }
                    .controlSize(.large).keyboardShortcut(.cancelAction)
            }
            Button(model.primaryTitle) { model.primary() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .reportsFooterFrame()
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
}
#endif
