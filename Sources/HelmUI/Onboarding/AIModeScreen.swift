#if os(macOS)
import AppKit
import HelmAgent
import SwiftUI

/// The AI mode screen: the welcome window's third mode, always dark. The spark sits over one soft glow, the title row
/// is the switch, and Done is the only button. Once the switch is on it shows the provider menu with its help, the
/// key field (or OpenAI's ChatGPT sign-in, or a local provider's state), and the line saying what is sent and to whom.
///
/// Embedded, it's the onboarding's AI step: the same parts in the Mac's own appearance, with no glow, no sentence (the
/// step's header has it) and no Done. The onboarding's Continue stands in for Done, through `continueRequests`.
struct AIModeScreen: View {
    @ObservedObject var model: AISetupModel
    var embedded = false
    /// Counts the onboarding's Continue presses. Each one hands over what was typed, as Done does.
    var continueRequests = 0
    /// A key being typed. It is handed to the model on Return or Done and the field is emptied; a saved key is never
    /// put back in it.
    @State private var draftKey = ""
    @State private var draftAddress = ""
    @State private var draftPort = ""
    @State private var draftModel = ""
    @FocusState private var keyFocused: Bool

    /// What the screen shows, top to bottom. The title row, with the switch, always comes first and Done always last.
    enum Part: Hashable {
        case titleRow, sentence, provider, address, chatGPT, key, useChatGPT, state, port, modelName, consent, done
    }

    /// The parts on show for how `model` stands now. The screen is drawn from this list.
    static func parts(for model: AISetupModel, embedded: Bool = false) -> [Part] {
        let parts = screenParts(for: model)
        return embedded ? parts.filter { $0 != .sentence && $0 != .done } : parts
    }

    private static func screenParts(for model: AISetupModel) -> [Part] {
        var parts: [Part] = [.titleRow, .sentence]
        if model.isOn {
            parts.append(.provider)
            if model.provider == .other { parts.append(.address) }
            if model.usesChatGPT { parts.append(.chatGPT) }
            if model.showsKeyField { parts.append(.key) }
            if model.showsKeyField, model.provider == .openAI { parts.append(.useChatGPT) }
            parts.append(.state)
            if model.showsPort { parts.append(.port) }
            if model.showsModelField { parts.append(.modelName) }
            parts.append(.consent)
        }
        parts.append(.done)
        return parts
    }

    /// The buttons on show, by title: Done, and Try Again beside a state it can help.
    static func buttonTitles(for model: AISetupModel) -> [String] {
        parts(for: model).flatMap { part -> [String] in
            switch part {
            case .done: return [AgentText.done]
            case .state: return model.offersTryAgain ? [AgentText.tryAgain] : []
            case .titleRow, .sentence, .provider, .address, .chatGPT, .key, .useChatGPT, .port, .modelName, .consent: return []
            }
        }
    }

    /// How far the parts sit from the edges: the screen's wide margins, or the step's card.
    private var inset: CGFloat { embedded ? 16 : 40 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded { AIModeMark() }
            ForEach(Self.parts(for: model, embedded: embedded), id: \.self) { part in view(for: part) }
        }
        .padding(.bottom, embedded ? 14 : 0)
        .frame(width: embedded ? nil : OnboardingView.width)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(AIModeChrome(embedded: embedded))
        .onChange(of: continueRequests) { _, _ in pressDone() }
        .onAppear {
            draftAddress = model.address
            focusKey()
        }
        .onChange(of: model.isOn) { _, _ in focusKey() }
        // A key typed but not yet entered belongs to the provider and address it was typed for: it never follows a
        // change of either.
        .onChange(of: model.provider) { _, _ in
            draftKey = ""
            draftAddress = model.address
            focusKey()
        }
        .onChange(of: model.address) { _, _ in
            draftKey = ""
            focusKey()
        }
        // Done couldn't close: the caret goes back to the key, the thing still missing.
        .onChange(of: model.refusedDone) { _, _ in focusKey() }
    }

    @ViewBuilder private func view(for part: Part) -> some View {
        switch part {
        case .titleRow:
            // Embedded, the step's header holds the title, so the switch has Settings' plain label.
            let label = embedded ? AgentText.settingsAIMode : AgentText.aiTitle
            HStack(alignment: .center) {
                Text(label)
                    .font(.system(size: embedded ? 13 : 26, weight: embedded ? .semibold : .bold))
                    .accessibilityAddTraits(embedded ? [] : .isHeader)
                Spacer(minLength: 12)
                Toggle(label, isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                    .toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel(label)
            }
            .padding(.horizontal, inset).padding(.top, embedded ? 14 : 8)
        case .sentence:
            Text(AgentText.aiSentence)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, inset).padding(.top, 6).padding(.bottom, 8)
        case .provider:
            HStack(spacing: 10) {
                Picker(AgentText.providerLabel, selection: Binding(get: { model.provider }, set: { model.choose($0) })) {
                    ForEach(AgentProviderID.allCases, id: \.self) { id in
                        Text(verbatim: AgentProviderCatalog.name(id)).tag(id)
                    }
                }
                .pickerStyle(.menu)
                AIProviderHelp(model: model)
            }
            .padding(.horizontal, inset).padding(.top, 12)
        case .chatGPT:
            AIChatGPTSection(model: model)
                .padding(.horizontal, inset).padding(.top, 12)
        case .useChatGPT:
            AIUseChatGPTLink(model: model)
                .padding(.horizontal, inset).padding(.top, 4)
        case .address:
            VStack(alignment: .leading, spacing: 6) {
                TextField(AgentText.addressLabel, text: $draftAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.setAddress(draftAddress) }
                if let problem = model.addressProblem { AIModeLine(text: problem, isProblem: true) }
            }
            .padding(.horizontal, inset).padding(.top, 12)
        case .key:
            // A saved key is never drawn; the prompt says it is there, and a paste replaces it.
            SecureField(model.hasSavedKey ? AgentText.keySaved : AgentText.keyPlaceholder, text: $draftKey)
                .textFieldStyle(.roundedBorder)
                .focused($keyFocused)
                .onSubmit { model.enterKey(takeDraftKey() ?? "") }
                .accessibilityLabel(AgentText.keyLabel)
                .padding(.horizontal, inset).padding(.top, 12)
        case .state:
            VStack(alignment: .leading, spacing: 4) { AIModeStateRow(model: model) }
                .padding(.horizontal, inset).padding(.top, 8)
        case .port:
            LabeledContent(AgentText.portLabel) {
                TextField(AgentText.portLabel, text: $draftPort, prompt: Text(verbatim: model.port.map(String.init) ?? ""))
                    .textFieldStyle(.roundedBorder).frame(width: 90).labelsHidden()
                    .onSubmit { model.setPort(draftPort); draftPort = "" }
            }
            .padding(.horizontal, inset).padding(.top, 8)
        case .modelName:
            TextField(AgentText.modelPlaceholder, text: $draftModel)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.typeModel(draftModel) }
                .padding(.horizontal, inset).padding(.top, 8)
        case .consent:
            Text(verbatim: model.consentLine)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, inset).padding(.top, 12)
        case .done:
            HStack {
                Spacer()
                Button(AgentText.done) { pressDone() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
        }
    }

    /// Done hands over everything typed and not yet entered: the address, the port and the model's name first, then
    /// the key, which the screen checks before it closes.
    private func pressDone() {
        model.commitTyped(address: draftAddress, port: draftPort, model: draftModel)
        draftPort = ""
        model.donePressed?(handOverDraftKey())
    }

    /// The typed key, once: the field is emptied as it is handed over.
    private func takeDraftKey() -> String? {
        let key = draftKey
        draftKey = ""
        return key.isEmpty ? nil : key
    }

    /// The typed key, for Done. A field still being typed in keeps its own copy of the text until it lets go of the
    /// caret, so the field lets go first and is emptied on the next turn, once its copy is gone; then it takes the
    /// caret back.
    private func handOverDraftKey() -> String? {
        let key = draftKey
        keyFocused = false
        DispatchQueue.main.async {
            draftKey = ""
            focusKey()
        }
        return key.isEmpty ? nil : key
    }

    /// The caret starts in the key field whenever there is one to type in.
    private func focusKey() {
        guard model.isOn, model.showsKeyField else { return }
        DispatchQueue.main.async { keyFocused = true }
    }
}

/// The AI mode screen's own look: dark, over the glow's background. Embedded in the onboarding, it takes the window's.
private struct AIModeChrome: ViewModifier {
    let embedded: Bool
    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content.background(AIModeMark.background).environment(\.colorScheme, .dark)
        }
    }
}

/// How the chosen provider stands, with Try Again beside a state it can help. Connected carries the green check
/// macOS shows beside an account that works.
struct AIModeStateRow: View {
    @ObservedObject var model: AISetupModel

    var body: some View {
        if let line = model.stateLine {
            HStack(spacing: 8) {
                if model.connection == .checking { ProgressView().controlSize(.small) }
                HStack(spacing: 4) {
                    if model.isConnected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
                            .accessibilityHidden(true)
                    }
                    AIModeLine(text: line, isProblem: model.stateIsProblem)
                }
                if model.offersTryAgain {
                    Button(AgentText.tryAgain) { model.tryAgain() }.controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// One line of Helm's own words: a state, or why an address wasn't taken.
struct AIModeLine: View {
    let text: String
    let isProblem: Bool
    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(isProblem ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The spark over one soft amber-to-violet glow. Both are drawn flat into images, with no blur, filter or motion, so
/// a capture of the window shows them as they look, and Reduce Motion has nothing to stop.
struct AIModeMark: View {
    static let height: CGFloat = 150
    static let background = Color(red: 0.067, green: 0.063, blue: 0.086)

    var body: some View {
        ZStack {
            Image(nsImage: Self.glow).resizable().interpolation(.high)
                .frame(width: 320, height: Self.height)
            Image(nsImage: SparkMark.image(size: 64, lit: true)).resizable().interpolation(.high)
                .frame(width: 64, height: 64)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .padding(.top, 18)
        .accessibilityHidden(true)
    }

    /// The glow: amber at the middle, through coral, to violet, fading out at the edge.
    static let glow: NSImage = {
        let size = NSSize(width: 640, height: 300)
        return NSImage(size: size, flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let colors = SparkMark.gradientColors
            let stops: [(NSColor, CGFloat, CGFloat)] = [(colors[0], 0.55, 0), (colors[1], 0.32, 0.4), (colors[2], 0.18, 0.72),
                                                        (colors[2], 0, 1)]
            let cgColors = stops.map { $0.0.withAlphaComponent($0.1).cgColor } as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cgColors,
                                            locations: stops.map(\.2)) else { return false }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            // Wider than tall: the glow is drawn round, then stretched.
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: bounds.width / bounds.height, y: 1)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                       endRadius: bounds.height / 2, options: [])
            context.restoreGState()
            return true
        }
    }()
}
#endif
