#if os(macOS)
import SwiftUI
import HelmAgent
import HelmCore

/// One entry of the thread. Every string from the model or the disk is drawn verbatim, as plain text that nothing
/// reads for links or formatting. Helm's own lines carry the spark and a quieter style, which a reply never gets.
struct AgentThreadLineView: View {
    let line: AgentPanelModel.Line
    @ObservedObject var model: AgentPanelModel

    var body: some View {
        switch line.kind {
        case .consent(let words):
            AgentHelmLineView(words: words, button: nil, press: {})
        case .request(let words):
            HStack {
                Spacer(minLength: 40)
                Text(verbatim: words)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
            }
        case .reply(let words):
            Text(verbatim: words)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .helm(let words, let button):
            AgentHelmLineView(words: words, button: button?.title) {
                if let button { model.pressButton(button, line: line.id) }
            }
        case .plan(let card):
            AgentPlanCardView(card: card,
                              toggle: { model.tick(group: $0, card: line.id) },
                              toggleOpen: { model.toggleOpen(group: $0, card: line.id) },
                              apply: { model.applyCard(line: line.id) },
                              cancel: { model.dismissCard(line: line.id) })
        case .outcome(let outcome):
            AgentOutcomeView(outcome: outcome, undo: { model.undo(line: line.id) }, show: { model.show(line: line.id) })
        }
    }
}

/// One of Helm's own lines: the spark, the words in the secondary colour, and a button when there is something
/// to press. The line saying what a running request does now has the system's small spinner in the spark's place,
/// so a long wait never looks stuck; it keeps still with Reduce Motion on.
struct AgentHelmLineView: View {
    let words: String
    let button: String?
    var isLive = false
    let press: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isLive {
                ProgressView().controlSize(.mini)
                    .frame(width: 10, height: 10)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    .accessibilityHidden(true)
            } else {
                Image(nsImage: SparkMark.image(size: 10, lit: false))
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(verbatim: words)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let button {
                Button(button, action: press).controlSize(.small)
            }
        }
    }
}

/// What an applied plan did, with Undo and Show.
struct AgentOutcomeView: View {
    let outcome: AgentPanelModel.Outcome
    let undo: () -> Void
    let show: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Once undone, what it did is no longer so, and the line says so by going quiet.
            Text(verbatim: outcome.lines.joined(separator: "\n"))
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(outcome.undoLine == AgentText.undoDone ? Color.secondary : Color.primary)
            if let undoLine = outcome.undoLine {
                Text(verbatim: undoLine).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if outcome.canUndo || !outcome.changed.isEmpty {
                HStack {
                    Spacer()
                    if !outcome.changed.isEmpty { Button(AgentText.show, action: show) }
                    if outcome.canUndo { Button(AgentText.undo, action: undo) }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

/// The folders AI mode can use: one chip each, with the kind's symbol, the folder's name, and a close button on a
/// folder the person added. The tooltip says where it is in words. When the chips are wider than the row, its
/// trailing edge fades, so the ones past it are seen to be there.
struct AgentFoldersRow: View {
    @ObservedObject var model: AgentPanelModel
    @State private var chipsWidth: CGFloat = 0
    @State private var rowWidth: CGFloat = 0
    static let fade: CGFloat = 16

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.chips) { chip in
                    AgentFolderChipView(chip: chip, remove: { model.remove(chip) })
                }
            }
            .padding(.horizontal, 10)
            .background(GeometryReader { proxy in Color.clear.preference(key: AgentChipsWidthKey.self, value: proxy.size.width) })
        }
        .background(GeometryReader { proxy in Color.clear.preference(key: AgentChipsRowWidthKey.self, value: proxy.size.width) })
        .onPreferenceChange(AgentChipsWidthKey.self) { chipsWidth = $0 }
        .onPreferenceChange(AgentChipsRowWidthKey.self) { rowWidth = $0 }
        .mask(mask)
        .frame(height: 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: AgentText.foldersRowLabel))
    }

    /// Solid while every chip fits; otherwise solid up to the last 16 points, which fade out.
    @ViewBuilder private var mask: some View {
        if AgentFoldersRow.fades(chips: chipsWidth, row: rowWidth) {
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: max(0, 1 - Self.fade / rowWidth)),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        } else {
            Rectangle()
        }
    }

    /// Whether chips this wide in a row this wide need the fade.
    static func fades(chips: CGFloat, row: CGFloat) -> Bool { row > 0 && chips > row + 0.5 }
}

/// How wide the chips are together, and how wide their row is.
struct AgentChipsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct AgentChipsRowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One folder's chip: the kind's symbol, the folder's name, and a close button on a folder the person added.
struct AgentFolderChipView: View {
    let chip: AgentPanelModel.Chip
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: chip.symbol).font(.system(size: 10)).accessibilityHidden(true)
            Text(verbatim: chip.label).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            if chip.removable {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: AgentText.chipRemove(chip.label)))
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .help(chip.tooltip)
        .frame(maxWidth: 200)
    }
}

/// The three suggestions, or the line said in their place. Organize runs as soon as it is pressed; on the folder its
/// menu offers how deep to go. Move and Copy fill the composer.
struct AgentSuggestionsRow: View {
    @ObservedObject var model: AgentPanelModel

    var body: some View {
        if !model.slashRows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.slashRows, id: \.title) { row in
                    Button(action: { model.press(row.title) }) {
                        Text(verbatim: row.title).font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                }
            }
            .padding(.horizontal, 6)
        } else if !model.suggestions.isEmpty {
            // Organize has a row of its own and Move and Copy share the next, so each title keeps its count and its
            // "to…" at the panel's fixed width.
            VStack(spacing: 6) {
                ForEach(model.suggestions.filter { $0.kind == .organize }) { chip(for: $0) }
                HStack(spacing: 6) {
                    ForEach(model.suggestions.filter { $0.kind != .organize }) { chip(for: $0) }
                }
            }
            .padding(.horizontal, 8)
        } else if let line = model.restingLine {
            Text(verbatim: line)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
        }
    }

    /// Organize on the folder offers how deep to go; on a selection the items are already chosen, so it is a plain
    /// button, as Move and Copy are.
    @ViewBuilder private func chip(for suggestion: AgentSuggestion) -> some View {
        if suggestion.kind == .organize, !suggestion.isSelection {
            // Drawn as the other chips are, the same type and height, with its chevron beside the words.
            Menu {
                ForEach(AgentPanelModel.depths, id: \.title) { depth in
                    Button(depth.title) { model.choose(suggestion, depth: depth.depth) }
                }
            } label: {
                Text(verbatim: suggestion.title).font(.system(size: 11)).foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            } primaryAction: {
                model.choose(suggestion, depth: .thisFolder)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.visible)
            .fixedSize()
            .modifier(AgentSuggestionLook())
        } else {
            Button(action: { model.choose(suggestion, depth: .thisFolder) }) {
                Text(verbatim: suggestion.title).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .buttonStyle(.plain)
            .modifier(AgentSuggestionLook())
        }
    }
}

/// A suggestion's chip: its row's full width or an equal share of it, one height for all three, a soft fill and
/// rounded corners.
private struct AgentSuggestionLook: ViewModifier {
    static let height: CGFloat = 24
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
    }
}
#endif
