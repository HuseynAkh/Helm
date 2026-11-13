#if os(macOS)
import SwiftUI
import HelmAgent
import HelmCore

/// The AI panel above its composer: the folders row, the thread, and the three suggestions just above the composer.
/// Its top is a fixed inset under the header, never a safe area the system works out, so the panel sits the same in
/// every build.
struct AgentPanelView: View {
    @ObservedObject var model: AgentPanelModel

    var body: some View {
        VStack(spacing: 0) {
            AgentFoldersRow(model: model)
                .padding(.top, AgentPanelHost.topInset)
                .padding(.bottom, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.lines) { line in
                            AgentThreadLineView(line: line, model: model).id(line.id)
                        }
                        if let status = model.status {
                            AgentHelmLineView(words: status, button: nil, press: {}).id(Self.statusID)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .onChange(of: model.lines.count) { _, _ in
                    if let last = model.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: model.status) { _, status in
                    if status != nil { proxy.scrollTo(Self.statusID, anchor: .bottom) }
                }
            }
            AgentSuggestionsRow(model: model)
                .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    private static let statusID = -1
}
#endif
