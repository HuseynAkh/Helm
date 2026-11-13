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
/// to press.
struct AgentHelmLineView: View {
    let words: String
    let button: String?
    let press: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(nsImage: SparkMark.image(size: 10, lit: false))
                .renderingMode(.template)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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
            Text(verbatim: outcome.lines.joined(separator: "\n"))
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
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
/// folder the person added. The tooltip says where it is in words.
struct AgentFoldersRow: View {
    @ObservedObject var model: AgentPanelModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.chips) { chip in
                    AgentFolderChipView(chip: chip, remove: { model.remove(chip) })
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: AgentText.foldersRowLabel))
    }
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

/// The three suggestions, or the line said in their place. Organize runs as soon as it is pressed; its menu offers
/// how deep to go. Move and Copy fill the composer.
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
            HStack(spacing: 6) {
                ForEach(model.suggestions) { suggestion in
                    if suggestion.kind == .organize {
                        Menu {
                            ForEach(AgentPanelModel.depths, id: \.title) { depth in
                                Button(depth.title) { model.choose(suggestion, depth: depth.depth) }
                            }
                        } label: {
                            Text(verbatim: suggestion.title).font(.system(size: 11)).lineLimit(1)
                        } primaryAction: {
                            model.choose(suggestion, depth: .thisFolder)
                        }
                        .menuStyle(.borderlessButton)
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
            .padding(.horizontal, 8)
        } else if let line = model.restingLine {
            Text(verbatim: line)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
        }
    }
}

/// A suggestion's chip: an equal share of the row, a soft fill and rounded corners.
private struct AgentSuggestionLook: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
    }
}
#endif
