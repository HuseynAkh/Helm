import Foundation

/// The terminal apps Open in Terminal can use. Each one opens a new window in a folder it's handed, which is how Helm
/// asks for it: Terminal and Ghostty say so in their own Info.plist, as the others do. Settings offers the ones on
/// this Mac that macOS lists as able to open a folder.
public enum TerminalApps {
    public struct App: Sendable, Equatable {
        /// Its bundle identifier, which Settings keeps.
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    /// Terminal, which every Mac has.
    public static let standard = "com.apple.Terminal"
    public static let known: [App] = [
        App(id: standard, name: "Terminal"),
        App(id: "com.mitchellh.ghostty", name: "Ghostty"),
        App(id: "com.googlecode.iterm2", name: "iTerm"),
        App(id: "dev.warp.Warp-Stable", name: "Warp"),
        App(id: "com.github.wez.wezterm", name: "WezTerm"),
        App(id: "net.kovidgoyal.kitty", name: "kitty")
    ]
    /// The name Settings shows for an identifier, or the identifier itself for one Helm doesn't know.
    public static func name(of id: String) -> String { known.first { $0.id == id }?.name ?? id }
}
