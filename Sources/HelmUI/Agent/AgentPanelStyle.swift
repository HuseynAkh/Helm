#if os(macOS)
import AppKit
import SwiftUI

/// The AI panel's look in one place: Helm's own type sizes, the panel's margins, and the soft fills of its bubbles,
/// chips, cards and field. Every colour is the system's or made from it, so the panel follows the window's light and
/// dark appearance and the accent colour chosen in System Settings.
enum AgentPanelStyle {
    /// The panel's side margins, the room inside a card, and the gap between the thread's entries.
    static let margin: CGFloat = 14
    static let inset: CGFloat = 12
    static let spacing: CGFloat = 12

    /// Requests, replies, suggestions, card titles and the composer: the size of the list's details, the tabs and
    /// the status bar.
    static let body: CGFloat = 13
    /// Helm's own lines, the folder chips, a card's counts and notes, and its items.
    static let secondary: CGFloat = 12
    /// Paths and tags.
    static let small: CGFloat = 11
    /// The extra room between a reply's lines, and a bubble's.
    static let replyLineSpacing: CGFloat = 3
    static let bubbleLineSpacing: CGFloat = 2

    static let cardRadius: CGFloat = 10
    static let bubbleRadius: CGFloat = 14
    static let chipRadius: CGFloat = 8
    /// How tall a suggestion is, and a folder chip.
    static let suggestionHeight: CGFloat = 28
    static let folderChipHeight: CGFloat = 24

    /// A person's message: the accent colour, lightly.
    static let bubbleFill = Color.accentColor.opacity(0.16)
    /// A grouped box, as System Settings draws its rows: nearly white over the material in light, a lifted grey in dark.
    static let cardFill = Color(nsColor: dynamic(light: NSColor(white: 1, alpha: 0.75), dark: NSColor(white: 1, alpha: 0.07)))
    static let cardBorder = Color(nsColor: dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.07)))
    /// A suggestion or a folder chip at rest, under the pointer, and pressed.
    static func chipFill(hovering: Bool = false, pressed: Bool = false) -> Color {
        Color.primary.opacity(pressed ? 0.15 : hovering ? 0.10 : 0.06)
    }
    /// The composer's field, its edge, and its edge while it has the keys.
    static let fieldFill = dynamic(light: NSColor(white: 1, alpha: 0.8), dark: NSColor(white: 1, alpha: 0.07))
    static let fieldBorder = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.12))
    static var fieldFocusBorder: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.7) }

    /// One colour for the light appearance and another for the dark, picked as each draws.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// A grouped box behind a card: rounded, filled and edged as System Settings draws its rows.
struct AgentCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: AgentPanelStyle.cardRadius, style: .continuous)
            .fill(AgentPanelStyle.cardFill)
            .overlay(RoundedRectangle(cornerRadius: AgentPanelStyle.cardRadius, style: .continuous)
                .strokeBorder(AgentPanelStyle.cardBorder, lineWidth: 1))
    }
}

/// A hairline between a card's rows, inset from its leading edge as grouped rows' are.
struct AgentCardSeparator: View {
    var leading: CGFloat = AgentPanelStyle.inset
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 0.5)
            .padding(.leading, leading)
    }
}

/// A suggestion's or a slash command's look: a soft rounded fill that darkens under the pointer and when pressed.
struct AgentChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AgentChipLook(pressed: configuration.isPressed) { configuration.label }
    }
}

/// The fill behind a chip-like control, which follows the pointer.
struct AgentChipLook<Label: View>: View {
    var pressed = false
    var radius: CGFloat = AgentPanelStyle.chipRadius
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        label()
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(AgentPanelStyle.chipFill(hovering: hovering, pressed: pressed)))
            .onHover { hovering = $0 }
    }
}
#endif
