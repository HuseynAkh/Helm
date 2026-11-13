import Foundation

/// Shows hidden and control characters as visible escapes, so a name from a disk or text from a model can't hide
/// anything from the person or from a model: a line break, a character that reverses the reading order, one that
/// takes no space, a private-use character.
///
/// What is escaped is decided by class, not from a list: every scalar in the Unicode categories Cc (control),
/// Cf (format), Zl and Zp (line and paragraph separators), Co (private use) and Cn (unassigned), and every code point
/// Unicode says to ignore by default, which adds the variation selectors and the blank fillers. The one exception is
/// the glue inside an emoji: U+200D and U+FE0F are kept only where they sit between two emoji.
public enum AgentTextEscaper {
    /// `text` with each such scalar written as `\u{…}`, its number in upper-case hexadecimal.
    public static func escape(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.indices.contains(where: { isEscaped(at: $0, in: scalars) }) else { return text }
        var result = String.UnicodeScalarView()
        for index in scalars.indices {
            if isEscaped(at: index, in: scalars) {
                result.append(contentsOf: "\\u{\(String(scalars[index].value, radix: 16, uppercase: true))}".unicodeScalars)
            } else {
                result.append(scalars[index])
            }
        }
        return String(result)
    }

    /// Whether `text` has nothing to escape, so `escape(text) == text`.
    public static func isClean(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return !scalars.indices.contains(where: { isEscaped(at: $0, in: scalars) })
    }

    private static func isEscaped(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
        isHidden(scalars[index]) && !isEmojiGlue(at: index, in: scalars)
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: return true
        default: return scalar.properties.isDefaultIgnorableCodePoint
        }
    }

    /// The only shapes kept are the ones emoji are written with: an emoji, then U+FE0F, U+200D or the two in that
    /// order, then another emoji. Anything longer, or beside a letter or a digit, is escaped like any hidden character.
    private static func isEmojiGlue(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
        func emoji(_ offset: Int) -> Bool { scalar(index + offset, in: scalars).map(isEmoji) ?? false }
        func value(_ offset: Int) -> UInt32? { scalar(index + offset, in: scalars)?.value }
        switch scalars[index].value {
        case joiner: return emoji(1) && (emoji(-1) || (value(-1) == presentation && emoji(-2)))
        case presentation: return emoji(-1) && (emoji(1) || (value(1) == joiner && emoji(2)))
        default: return false
        }
    }

    private static let joiner: UInt32 = 0x200D
    private static let presentation: UInt32 = 0xFE0F

    private static func scalar(_ index: Int, in scalars: [Unicode.Scalar]) -> Unicode.Scalar? {
        scalars.indices.contains(index) ? scalars[index] : nil
    }

    /// A pictograph. Digits, `#` and `*` are emoji to Unicode as well, as the base of a keycap; a joiner beside one of
    /// those would be hidden inside ordinary text, so they don't count.
    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0xFF && scalar.properties.isEmoji
    }
}
