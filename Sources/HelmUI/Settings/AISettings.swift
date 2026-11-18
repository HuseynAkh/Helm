#if os(macOS)
import AppKit
import Combine
import HelmAgent
import SwiftUI

/// Settings › AI: the switch with the consent line as its footer, as General's switches have theirs, and once it is
/// on the provider with its help, its key (or OpenAI's ChatGPT sign-in, or a local provider's state) and its model.
/// Drawn from the same model as the AI mode screen. Settings has no Done, so what is typed is entered on Return, as
/// the caret leaves a field, or as the pane goes away.
struct AISettingsView: View {
    @ObservedObject var model: AISetupModel
    @State private var draftKey = ""
    /// Who the typed key is for: the provider and address shown when it was typed.
    @State private var draftKeyFor: String?
    @FocusState private var keyFocused: Bool
    @State private var draftAddress = ""
    @State private var draftPort = ""
    @State private var draftModel = ""
    /// The field with the caret, among the address, the port and the model's name.
    enum Field: Hashable { case address, port, model }
    @FocusState private var focused: Field?

    static let width: CGFloat = 560

    var body: some View {
        Form {
            Section {
                Toggle(AgentText.settingsAIMode, isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
            } footer: {
                Text(verbatim: model.consentLine)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.isOn {
                Section {
                    HStack(spacing: 10) {
                        Picker(AgentText.providerLabel, selection: Binding(get: { model.provider }, set: { model.choose($0) })) {
                            ForEach(AgentProviderID.allCases, id: \.self) { id in
                                Text(verbatim: AgentProviderCatalog.name(id)).tag(id)
                            }
                        }
                        AIProviderHelp(model: model)
                    }
                    if model.provider == .other { address }
                    if model.usesChatGPT {
                        VStack(alignment: .leading, spacing: 4) {
                            AIChatGPTSection(model: model)
                            AIModeStateRow(model: model)
                        }
                    } else if model.showsKeyField {
                        key
                    } else if !model.takesKey {
                        localState
                    }
                    // Other has no models to offer until an address has been taken.
                    if model.provider != .other || model.hasProfile { modelRow }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.width)
        .onAppear { draftAddress = model.address }
        // Settings has no Done, so a key, an address, a port or a model typed and not yet entered is entered as the
        // pane goes away.
        .onDisappear {
            enterDraftKey(onlyFor: keyOwner)
            commitTyped(address: true, port: true, model: true)
        }
        // Leaving a field enters what was typed in it, as Return does.
        .onChange(of: focused) { old, now in
            guard let old, old != now else { return }
            commitTyped(address: old == .address, port: old == .port, model: old == .model)
        }
        // A key typed but not yet entered never follows a change of provider or address.
        .onChange(of: model.provider) { _, _ in
            draftKey = ""
            draftAddress = model.address
        }
        .onChange(of: model.address) { _, _ in draftKey = "" }
        .onChange(of: draftKey) { _, typed in draftKeyFor = typed.isEmpty ? nil : keyOwner }
    }

    private var address: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(AgentText.addressLabel, text: $draftAddress, prompt: Text(AgentText.addressPrompt))
                .focused($focused, equals: .address)
                .onSubmit { model.setAddress(draftAddress) }
            if let problem = model.addressProblem { AIModeLine(text: problem, isProblem: true) }
        }
    }

    /// The key field, its state and Remove Key. The field is always empty: a saved key is never drawn.
    private var key: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // A saved key is never drawn; the prompt says it is there, and a paste replaces it.
                SecureField(AgentText.keyLabel, text: $draftKey,
                            prompt: Text(model.hasSavedKey ? AgentText.keySaved : AgentText.keyPlaceholder))
                    .focused($keyFocused)
                    .onSubmit { enterDraftKey() }
                    // Leaving the field enters what was typed, as Return does.
                    .onChange(of: keyFocused) { _, focused in if !focused { enterDraftKey(onlyFor: keyOwner) } }
                if model.hasSavedKey { Button(AgentText.removeKey) { model.removeKey() } }
            }
            AIModeStateRow(model: model)
            if model.provider == .openAI { AIUseChatGPTLink(model: model) }
        }
    }

    /// Enters the typed key, once. Return enters it for the provider on show; leaving the field or the pane enters it
    /// only when `onlyFor` is the provider and address it was typed for.
    private func enterDraftKey(onlyFor owner: String? = nil) {
        let typed = draftKey
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.showsKeyField else { return }
        if let owner, draftKeyFor != owner { return }
        draftKey = ""
        draftKeyFor = nil
        model.enterKey(typed)
    }

    private var keyOwner: String { model.provider.rawValue + "|" + model.address }

    /// Enters the address, the port or the model's name that was typed and not yet entered.
    private func commitTyped(address: Bool, port: Bool, model commitsModel: Bool) {
        model.commitTyped(address: address ? draftAddress : nil, port: port ? draftPort : nil,
                          model: commitsModel ? draftModel : nil)
        if port { draftPort = "" }
    }

    /// A local provider's state in place of a key, and its port beside "isn't running" or "Can't reach".
    private var localState: some View {
        VStack(alignment: .leading, spacing: 4) {
            AIModeStateRow(model: model)
            if model.showsPort {
                TextField(AgentText.portLabel, text: $draftPort, prompt: Text(verbatim: model.port.map(String.init) ?? ""))
                    .focused($focused, equals: .port)
                    .onSubmit {
                        model.setPort(draftPort)
                        draftPort = ""
                    }
            }
        }
    }

    /// A menu of what the provider lists, or for Other with no list a field to type the model's name in.
    @ViewBuilder private var modelRow: some View {
        if model.showsModelField {
            TextField(AgentText.modelLabel, text: $draftModel, prompt: Text(AgentText.modelPlaceholder))
                .focused($focused, equals: .model)
                .onSubmit { model.typeModel(draftModel) }
        } else {
            HStack(spacing: 10) {
                Picker(AgentText.modelLabel, selection: Binding(get: { model.model ?? "" }, set: { model.chooseModel($0) })) {
                    if model.model == nil { Text(verbatim: "").tag("") }
                    ForEach(model.modelChoices, id: \.self) { id in Text(verbatim: model.modelTitle(id)).tag(id) }
                }
                .disabled(model.modelChoices.isEmpty)
                AIRefreshModelsButton(model: model)
            }
        }
    }

    /// The pane's height as it is drawn now, never less than the pane's usual height.
    static func height(for model: AISetupModel) -> CGFloat {
        let view = AISettingsView(model: model).fixedSize(horizontal: false, vertical: true).frame(width: width)
        return max(SettingsPane.ai.height, NSHostingView(rootView: view).fittingSize.height.rounded(.up))
    }
}

extension SettingsWindowController {
    /// Gives Settings › AI its model. The window fits the pane again whenever what it shows changes.
    public func showAI(_ model: AISetupModel) {
        guard aiSetupModel == nil else { return }
        let host = AISettingsHost(rootView: AISettingsView(model: model))
        host.sizingOptions = []
        replacePane(.ai, with: host) { AISettingsView.height(for: model) }
        // The model says it will change before the form redraws, so the pane is fitted after the redraw, and once
        // more a moment later for rows that come in as the form lays out.
        host.refit = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fitPane() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { self?.fitPane() } }
        }
    }
    /// What Settings › AI shows and changes, once the app has given it one.
    public var aiSetupModel: AISetupModel? { (paneController(.ai) as? AISettingsHost)?.rootView.model }
}

/// Settings › AI's pane, which keeps the window fitting it for as long as the pane is there.
final class AISettingsHost: NSHostingController<AISettingsView> {
    var refit: AnyCancellable?
}
#endif
