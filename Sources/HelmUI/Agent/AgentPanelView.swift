#if os(macOS)
import SwiftUI
import HelmAgent
import HelmCore

/// The AI panel above its composer: the folders row, the thread, and Organize just above the composer.
/// Its top is a fixed inset under the header, never a safe area the system works out, so the panel sits the same in
/// every build. It draws no background of its own: the host's material shows through, as the sidebar's does.
struct AgentPanelView: View {
    @ObservedObject var model: AgentPanelModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AgentFoldersRow(model: model)
                folderRowEnd
            }
            .padding(.top, AgentPanelHost.topInset)
            .padding(.bottom, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: AgentPanelStyle.spacing) {
                        ForEach(model.lines) { line in
                            AgentThreadLineView(line: line, model: model).id(line.id)
                        }
                        if let status = model.status {
                            AgentHelmLineView(words: status, button: nil, isLive: true, press: {}).id(Self.statusID)
                        }
                    }
                    .padding(.horizontal, AgentPanelStyle.margin)
                    .padding(.vertical, AgentPanelStyle.margin)
                }
                .onChange(of: model.lines.count) { _, _ in
                    if let last = model.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: model.status) { _, status in
                    if status != nil { proxy.scrollTo(Self.statusID, anchor: .bottom) }
                }
            }
            AgentSuggestionsRow(model: model)
                .padding(.top, 6)
                .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    /// The trailing end of the folders row, after the chips, kept for a control that belongs to the row. Empty for
    /// now. A control here keeps the panel's margin on its trailing side.
    /// The trailing end of the folders row: the This Folder / Whole Mac switch.
    @ViewBuilder private var folderRowEnd: some View {
        AgentScopeSwitch(model: model)
    }

    private static let statusID = -1
}
#endif
