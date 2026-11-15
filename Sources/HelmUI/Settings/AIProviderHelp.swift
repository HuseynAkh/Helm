#if os(macOS)
import HelmAgent
import SwiftUI

/// Beside the provider menu, on the AI Mode screen and in Settings › AI: an info button whose tooltip says in one
/// sentence what the provider uses and what it costs, and a "How to connect" link to the provider's own page. A click
/// on the info button shows the same sentence and link, for a person who doesn't hover. Links go to the browser
/// through the app's opener.
struct AIProviderHelp: View {
    @ObservedObject var model: AISetupModel
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 6) {
            Button { showsDetails.toggle() } label: {
                Image(systemName: "info.circle").imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .help(model.helpLine)
            .accessibilityLabel(AgentText.aboutProvider(model.providerName))
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: model.helpLine)
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    if model.helpPage != nil {
                        Button(AgentText.howToConnect) { model.openHowToConnect() }.buttonStyle(.link)
                    }
                }
                .padding(12)
                .frame(width: 260, alignment: .leading)
            }
            if model.helpPage != nil {
                Button(AgentText.howToConnect) { model.openHowToConnect() }
                    .buttonStyle(.link).font(.system(size: 12))
                    .help(model.helpLine)
            }
        }
    }
}

/// OpenAI with a ChatGPT sign-in: "Continue with ChatGPT" until signed in, then who is signed in with Remove and
/// "Manage usage". A sign-in under way says to continue in the browser, with Cancel. "Use an API key instead" sits
/// under it, quietly.
struct AIChatGPTSection: View {
    @ObservedObject var model: AISetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let account = model.accountLine {
                HStack(spacing: 8) {
                    Text(verbatim: account).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(AgentText.manageUsage) { model.openManageUsage() }.buttonStyle(.link).font(.system(size: 12))
                    Button(AgentText.removeSignIn) { model.removeSignIn() }.controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Button(AgentText.continueWithChatGPT) { model.continueWithChatGPT() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.signIn == .waiting)
                    if model.signIn == .waiting {
                        ProgressView().controlSize(.small)
                        Button(AgentText.cancel) { model.cancelSignIn() }.controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let line = model.signInLine {
                AIModeLine(text: line, isProblem: model.signIn != .waiting)
            }
            if let line = model.signOutLine {
                AIModeLine(text: line, isProblem: true)
            }
            Button(AgentText.useKeyInstead) { model.useKey(true) }
                .buttonStyle(.link).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Under OpenAI's key field: the way back to the ChatGPT sign-in.
struct AIUseChatGPTLink: View {
    @ObservedObject var model: AISetupModel

    var body: some View {
        Button(AgentText.useChatGPTInstead) { model.useKey(false) }
            .buttonStyle(.link).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

/// Beside the model menu: asks the provider for its models again, such as after loading another model in LM Studio.
struct AIRefreshModelsButton: View {
    @ObservedObject var model: AISetupModel

    var body: some View {
        Button { model.refreshModels() } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.borderless)
            .help(AgentText.refreshModels)
            .accessibilityLabel(AgentText.refreshModels)
            .disabled(!model.canRefreshModels)
    }
}
#endif
