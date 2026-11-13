import Foundation

/// The one check on text Helm builds before it leaves the app: the context note and every tool result. Names can't
/// hold a slash, so an honest note or result never holds the home folder's path; one that does is never sent.
/// Nothing a person typed goes through this, since a path typed in a sentence is sent as typed.
public enum AgentOutboundCheck {
    /// False when `text` holds the home folder's path, as written or with its slashes escaped as JSON may write them.
    public static func helmTextIsClean(_ text: String, home: String) -> Bool {
        var path = home
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.count > 1, path.hasPrefix("/") else { return true }
        let escaped = path.replacingOccurrences(of: "/", with: "\\/")
        return !text.contains(path) && !text.contains(escaped)
    }
}
