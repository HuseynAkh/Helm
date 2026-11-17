import Foundation

/// The one check on text Helm builds before it leaves the app: the context note and every tool result. Names can't
/// hold a slash, so an honest note or result never holds the home folder's path; one that does is never sent.
/// Nothing a person typed goes through this, since a path typed in a sentence is sent as typed.
public enum AgentOutboundCheck {
    /// False when `text` holds the home folder's path in any of its spellings (`homeSpellings`), as written or with
    /// its slashes escaped as JSON may write them, in any case and in either Unicode form.
    public static func helmTextIsClean(_ text: String, home: String) -> Bool {
        for spelling in homeSpellings(home) {
            let escaped = spelling.replacingOccurrences(of: "/", with: "\\/")
            if text.range(of: spelling, options: .caseInsensitive) != nil || text.range(of: escaped, options: .caseInsensitive) != nil {
                return false
            }
        }
        return true
    }

    /// The ways a text can spell the home folder's path, longest first: as written; percent-encoded as in a file URL,
    /// from its composed and its decomposed form; and each of those after `file://`. Matched without case, and in
    /// Foundation's default comparison, which takes a composed letter and its decomposed form as the same. None for a
    /// path that isn't absolute or is the root.
    static func homeSpellings(_ home: String) -> [String] {
        var path = home
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.count > 1, path.hasPrefix("/") else { return [] }
        var spellings = [path]
        for form in [path.precomposedStringWithCanonicalMapping, path.decomposedStringWithCanonicalMapping] {
            if let encoded = form.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !spellings.contains(encoded) {
                spellings.append(encoded)
            }
        }
        spellings += spellings.map { "file://" + $0 }
        return spellings.sorted { $0.utf8.count > $1.utf8.count }
    }
}
