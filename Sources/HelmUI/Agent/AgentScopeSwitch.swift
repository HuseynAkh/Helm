#if os(macOS)
import SwiftUI
import HelmAgent

/// The switch at the trailing end of the folders row: This Folder or Whole Mac, for the thread on show. Either half
/// starts a new thread, and it can't be pressed while a request, an Apply or an Undo runs.
struct AgentScopeSwitch: View {
    @ObservedObject var model: AgentPanelModel

    var body: some View {
        Picker(selection: Binding(get: { model.scopeMode }, set: { model.chooseScope($0) })) {
            Text(verbatim: AgentText.scopeThisFolder).tag(AgentScopeMode.thisFolder)
            Text(verbatim: AgentText.scopeWholeMac).tag(AgentScopeMode.wholeMac)
        } label: {
            Text(verbatim: AgentText.scopeSwitchLabel)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(!model.canChooseScope)
        .help(AgentText.scopeSwitchHelp)
        .accessibilityLabel(Text(verbatim: AgentText.scopeSwitchLabel))
        .padding(.trailing, 10)
    }
}

extension View {
    /// This view with the scope switch after it, at the trailing end. The folders row wears it.
    func withAgentScopeSwitch(_ model: AgentPanelModel) -> some View {
        HStack(spacing: 6) {
            self
            AgentScopeSwitch(model: model)
        }
    }
}
#endif
