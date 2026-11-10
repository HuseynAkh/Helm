#if os(macOS)
import AppKit
import CoreText

/// How a grid item's name is shown (P-035): wrapped at word boundaries, as many lines as it needs up to a limit.
/// A name that needs more gets one cut in the middle of its last line, so the start and the end both stay in view,
/// the extension with them, as in Finder. Nothing that fits is shortened.
struct GridNameLines: Equatable {
    /// The lines on show, top to bottom.
    let lines: [String]
    /// Whether part of the name was left out, in which case the full name is in the tooltip (P-053).
    let isShortened: Bool
    /// The label's words. A name that fits is the label's to wrap, as before; a shortened one is its lines, one per
    /// paragraph, so the label draws exactly those.
    let text: String
    init(lines: [String], isShortened: Bool, text: String? = nil) {
        self.lines = lines; self.isShortened = isShortened
        self.text = text ?? lines.joined(separator: "\n")
    }
}

/// Works out a name's lines. A pure function of the name, the width and the font; `GridNameCache` keeps the answers.
enum GridNameShortener {
    static let ellipsis = "\u{2026}"
    /// The longest ending kept whole as an extension, such as ".numbers" or ".download".
    static let longestExtension = 15

    /// The lines `name` takes in `font` when each line has `width` points of text, at most `maxLines` of them.
    static func lines(for name: String, width: CGFloat, font: NSFont, maxLines: Int) -> GridNameLines {
        // A line break in a file name would start a line of its own, so it shows as a space.
        let shown = String(name.map { $0.isNewline ? " " : $0 })
        guard !shown.isEmpty, maxLines > 0, width > 0 else { return GridNameLines(lines: [shown], isShortened: false) }
        let text = shown as NSString
        let typesetter = LabelTypesetter(font: font)
        // Where the label itself ends each line of what's left.
        var ahead = typesetter.lineLengths(of: shown, width: width)
        // A name that fits is shown whole, and the label wraps it itself, exactly as before.
        if ahead.count <= maxLines {
            var start = 0
            let lines = ahead.map { count -> String in
                defer { start += count }
                return trimmingEnd(text.substring(with: NSRange(location: start, length: count)))
            }
            return GridNameLines(lines: lines, isShortened: false, text: shown)
        }
        // A longer one keeps its first lines as the label breaks them, then the rest is cut on the last line.
        var lines: [String] = []
        var start = 0
        while lines.count < maxLines - 1 {
            if ahead.isEmpty { ahead = typesetter.lineLengths(of: text.substring(from: start), width: width) }
            var count = ahead.first ?? 0
            // On a line of its own, a piece can come out a little wider than it was inside the name, such as a word
            // broken between two letters or an Arabic letter taking its final form, and the label would wrap it
            // again. Such a line is laid out again a little narrower, until it fits.
            var limit = width, narrowed = false
            while count > 1, limit > 1 {
                let over = measure(trimmingEnd(text.substring(with: NSRange(location: start, length: count))), font) - width
                guard over > 0 else { break }
                limit -= max(0.25, over)
                ahead = typesetter.lineLengths(of: text.substring(from: start), width: limit)
                count = ahead.first ?? 0
                narrowed = true
            }
            guard count > 0, start + count < text.length else { break }
            lines.append(trimmingEnd(text.substring(with: NSRange(location: start, length: count))))
            start += count
            // After a line laid out narrower, the rest is laid out again at the full width.
            if narrowed { ahead = [] } else { ahead.removeFirst() }
        }
        let rest = Array(text.substring(from: start))
        lines.append(cut(rest, keeping: extensionLength(of: shown), width: width, font: font))
        return GridNameLines(lines: lines, isShortened: true)
    }

    /// One line from `rest`, which doesn't fit: its start, an ellipsis and its end, as much of each as fits. The end
    /// keeps at least the last `ending` characters (the extension) when they fit, and otherwise as much as fits.
    static func cut(_ rest: [Character], keeping ending: Int, width: CGFloat, font: NSFont) -> String {
        let room = width - measure(ellipsis, font)
        guard room > 0, rest.count > 1 else { return ellipsis }
        let kept = min(ending, rest.count - 1)
        let keptWidth = kept > 0 ? measure(String(rest.suffix(kept)), font) : 0
        // Half the room each, unless the extension needs more than half.
        let tailRoom = min(room, max(room / 2, keptWidth))
        var tail = min(fitting(rest, fromEnd: true, within: tailRoom, font: font), rest.count - 1)
        let tailWidth = tail > 0 ? measure(String(rest.suffix(tail)), font) : 0
        var head = max(0, min(fitting(rest, fromEnd: false, within: room - tailWidth, font: font), rest.count - 1 - tail))
        func fits(_ head: Int, _ tail: Int) -> Bool {
            head + tail < rest.count && measure(joined(rest, head, tail), font) <= width
        }
        // What's left over goes to the start, then the end, a character at a time.
        var grew = true
        while grew {
            grew = false
            if fits(head + 1, tail) { head += 1; grew = true }
            if fits(head, tail + 1) { tail += 1; grew = true }
        }
        // Measured whole, the line can come out a little wider than its parts, such as with kerning across the cut.
        while head + tail > 0, !fits(head, tail) {
            if head > 0, head >= tail || tail <= kept { head -= 1 } else { tail -= 1 }
        }
        return joined(rest, head, tail)
    }

    /// The first `head` and last `tail` characters of `rest` either side of an ellipsis, without spaces at the cut.
    static func joined(_ rest: [Character], _ head: Int, _ tail: Int) -> String {
        trimmingEnd(String(rest.prefix(head))) + ellipsis + String(String(rest.suffix(tail)).drop { $0.isWhitespace })
    }

    /// How many characters, taken from the start or the end, fit in `limit` points.
    static func fitting(_ characters: [Character], fromEnd: Bool, within limit: CGFloat, font: NSFont) -> Int {
        var low = 0, high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            let piece = fromEnd ? String(characters.suffix(middle)) : String(characters.prefix(middle))
            if measure(piece, font) <= limit { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The characters of the name's extension, its dot included, or 0. A name that starts with its only dot, such as
    /// ".gitignore", has none, and neither has an ending with spaces in it, such as "Version 2.0 notes".
    static func extensionLength(of name: String) -> Int {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return 0 }
        let ending = name[name.index(after: dot)...]
        guard !ending.isEmpty, ending.count <= longestExtension, !ending.contains(where: \.isWhitespace) else { return 0 }
        return ending.count + 1
    }

    static func trimmingEnd(_ line: String) -> String {
        var line = Substring(line)
        while let last = line.last, last.isWhitespace { line = line.dropLast() }
        return String(line)
    }

    /// The width of `text` set on one line in `font`, the way the label sets it.
    static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

/// TextKit set up the way a wrapping label sets its words, so its line breaks are the label's own: at word
/// boundaries, with the standard strategy that keeps a Korean word whole and moves a word down rather than leave it
/// alone on the last line. CoreText's own suggestions do neither.
final class LabelTypesetter {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private let attributes: [NSAttributedString.Key: Any]

    init(font: NSFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        attributes = [.font: font, .paragraphStyle: paragraph]
        // The width given is the text's own, inside the label's margins.
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }

    /// How many UTF-16 units of `text` each of its lines takes, top to bottom, when lines are `width` points wide.
    func lineLengths(of text: String, width: CGFloat) -> [Int] {
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        layout.ensureLayout(for: container)
        var lengths: [Int] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { [layout] _, _, _, glyphs, _ in
            lengths.append(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).length)
        }
        return lengths
    }
}

/// Each name's lines, worked out once per name, width, font and line limit, so scrolling through thousands of items
/// only looks up what it worked out before.
@MainActor final class GridNameCache {
    static let shared = GridNameCache()
    private struct Key: Hashable {
        let name: String
        let width: CGFloat
        let font: String
        let size: CGFloat
        let maxLines: Int
    }
    private var stored: [Key: GridNameLines] = [:]
    private let capacity: Int
    /// How many times lines were worked out rather than found, for tests.
    private(set) var computed = 0

    init(capacity: Int = 20_000) { self.capacity = max(1, capacity) }

    func lines(for name: String, width: CGFloat, font: NSFont, maxLines: Int) -> GridNameLines {
        let key = Key(name: name, width: width, font: font.fontName, size: font.pointSize, maxLines: maxLines)
        if let found = stored[key] { return found }
        computed += 1
        let lines = GridNameShortener.lines(for: name, width: width, font: font, maxLines: maxLines)
        // A full cache starts again, rather than keeping track of what was used last.
        if stored.count >= capacity { stored.removeAll(keepingCapacity: true) }
        stored[key] = lines
        return lines
    }
}

/// Heights of grid names as the label lays them out.
@MainActor enum GridNameMetrics {
    private static var lineHeights: [String: CGFloat] = [:]
    private static let measuring = GridNameLabel(wrappingLabelWithString: "")

    /// One line of a name in `font`. Every line of the label is this tall, whatever the script.
    static func lineHeight(for font: NSFont) -> CGFloat {
        let key = "\(font.fontName) \(font.pointSize)"
        if let height = lineHeights[key] { return height }
        let height = self.height(of: "Hg", labelWidth: 10_000, font: font)
        lineHeights[key] = height
        return height
    }

    /// What a label with a frame `labelWidth` points wide needs to show `text` whole, wrapped, as the rename field does.
    static func height(of text: String, labelWidth: CGFloat, font: NSFont) -> CGFloat {
        measuring.font = font
        measuring.stringValue = text.isEmpty ? " " : text
        let size = measuring.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: labelWidth, height: 100_000)) ?? .zero
        return ceil(size.height)
    }
}

/// Where a grid item puts its icon and name, for one icon size and text size.
struct GridItemMetrics: Equatable {
    /// Lines a name takes at most, and while it's the one item selected.
    static let linesShown = 2
    static let linesSelected = 5
    static let iconTop: CGFloat = 4
    static let nameGap: CGFloat = 4
    static let nameInset: CGFloat = 4
    static let bottom: CGFloat = 12

    let iconSize: CGFloat
    let lineHeight: CGFloat

    var cellSize: NSSize {
        NSSize(width: iconSize + 56, height: Self.iconTop + iconSize + Self.nameGap + CGFloat(Self.linesShown) * lineHeight + Self.bottom)
    }
    /// The label as its constraints place it: the item's width less the name's inset on each side.
    var labelWidth: CGFloat { cellSize.width - 2 * Self.nameInset }
    /// The label's frame, which runs `GridNameLabel.outset` points past its constraints on each side.
    var labelFrameWidth: CGFloat { labelWidth + 2 * GridNameLabel.outset }
    /// The width the name's text has, inside the label's own margins.
    var textWidth: CGFloat { labelFrameWidth - GridNameLabel.textInset }
    /// How far a name of `lines` lines runs past the bottom of its item.
    func overflow(lines: Int) -> CGFloat { CGFloat(max(0, lines - Self.linesShown)) * lineHeight }
}
#endif
