#if os(macOS)
import AppKit
import Combine
import HelmAgent
import SwiftUI

/// Settings › AI: the switch with the consent line under it, and once it is on the provider, its key (or a local
/// provider's state) and its model. Drawn from the same model as the AI mode screen.
struct AISettingsView: View {
    @ObservedObject var model: AISetupModel
    @State private var draftKey = ""
    @State private var draftAddress = ""
    @State private var draftPort = ""
    @State private var draftModel = ""

    static let width: CGFloat = 560

    var body: some View {
        Form {
            Section {
                Toggle(AgentText.settingsAIMode, isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                Text(verbatim: model.consentLine)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.isOn {
                Section {
                    Picker(AgentText.providerLabel, selection: Binding(get: { model.provider }, set: { model.choose($0) })) {
                        ForEach(AgentProviderID.allCases, id: \.self) { id in
                            Text(verbatim: AgentProviderCatalog.name(id)).tag(id)
                        }
                    }
                    if model.provider == .other { address }
                    if model.showsKeyField { key } else if !model.takesKey { localState }
                    modelRow
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.width)
        .onAppear { draftAddress = model.address }
        // A key typed but not yet entered never follows a change of provider or address.
        .onChange(of: model.provider) { _, _ in
            draftKey = ""
            draftAddress = model.address
        }
        .onChange(of: model.address) { _, _ in draftKey = "" }
    }

    private var address: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(AgentText.addressLabel, text: $draftAddress)
                .onSubmit { model.setAddress(draftAddress) }
            if let problem = model.addressProblem { AIModeLine(text: problem, isProblem: true) }
        }
    }

    /// The key field, its state and Remove Key. The field is always empty: a saved key is never drawn.
    private var key: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(AgentText.keyLabel, text: $draftKey, prompt: Text(AgentText.keyPlaceholder))
                    .onSubmit {
                        let typed = draftKey
                        draftKey = ""
                        model.enterKey(typed)
                    }
                if model.hasSavedKey { Button(AgentText.removeKey) { model.removeKey() } }
            }
            AIModeStateRow(model: model)
        }
    }

    /// A local provider's state in place of a key, and its port beside "isn't running".
    private var localState: some View {
        VStack(alignment: .leading, spacing: 4) {
            AIModeStateRow(model: model)
            if model.showsPort {
                TextField(AgentText.portLabel, text: $draftPort, prompt: Text(verbatim: model.port.map(String.init) ?? ""))
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
                .onSubmit { model.typeModel(draftModel) }
        } else {
            Picker(AgentText.modelLabel, selection: Binding(get: { model.model ?? "" }, set: { model.chooseModel($0) })) {
                if model.model == nil { Text(verbatim: "").tag("") }
                ForEach(model.modelChoices, id: \.self) { id in Text(verbatim: id).tag(id) }
            }
            .disabled(model.modelChoices.isEmpty)
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
        host.refit = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fitPane() } }
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
