import Foundation
import HelmCore

/// A model's reply as the panel may show it: plain text, with nothing hidden in it and nothing that passes for one
/// of Helm's own lines.
public enum AgentReplyText {
    /// Each line is escaped, so a hidden or control character shows as `\u{…}`; a line that starts with "[Helm]" or
    /// "Helm:" loses that start; and the whole is cut at `limit` characters, never inside an escape.
    public static func clean(_ text: String, limit: Int) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let cleaned = lines.map { line -> String in
            var rest = Substring(AgentTextEscaper.escape(String(line)))
            while true {
                let trimmed = rest.drop { $0 == " " || $0 == "\t" }
                guard let prefix = helmPrefixes.first(where: { trimmed.lowercased().hasPrefix($0) }) else { break }
                rest = trimmed.dropFirst(prefix.count).drop { $0 == " " }
            }
            return String(rest)
        }.joined(separator: "\n")
        guard cleaned.count > max(0, limit) else { return cleaned }
        var cut = String(cleaned.prefix(max(0, limit)))
        // An escape cut in two would read as something else; it goes whole or not at all.
        if let start = cut.range(of: "\\u{", options: .backwards), !cut[start.upperBound...].contains("}") {
            cut = String(cut[..<start.lowerBound])
        }
        return cut
    }

    private static let helmPrefixes = ["[helm]", "helm:"]
}
