#if os(macOS)
import AppKit
import HelmCore

/// Recent's group headings, one look for the grid and the list: a short dim semibold label, then a hairline to the
/// edge. There's no background and nothing sticks while scrolling, so the flat, translucent content stays as it is,
/// like the sidebar's thin lines between its groups.
@MainActor final class SectionHeadingView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let line = NSBox()
    private var labelLeading: NSLayoutConstraint?
    private var labelBottom: NSLayoutConstraint?
    private var lineTrailing: NSLayoutConstraint?
    private var trailingInset: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.boxType = .separator
        for view in [label, line] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20)
        let bottom = label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        let trailing = line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        labelLeading = leading; labelBottom = bottom; lineTrailing = trailing
        NSLayoutConstraint.activate([
            leading, bottom, trailing,
            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            line.centerYAnchor.constraint(equalTo: label.centerYAnchor, constant: 1)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        // VoiceOver reads the heading once, from its own label ("Folders, 2 items"), not the words inside it again.
        label.cell?.setAccessibilityElement(false)
        line.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    /// `leading` lines the label up with the items below; `bottom` keeps it close to the group it names.
    func apply(title: String, count: Int, textSize: CGFloat, leading: CGFloat, trailing: CGFloat, bottom: CGFloat) {
        label.stringValue = title
        label.font = .systemFont(ofSize: max(11, textSize - 2), weight: .semibold)
        labelLeading?.constant = leading; labelBottom?.constant = -bottom
        trailingInset = trailing
        needsLayout = true
        setAccessibilityLabel(count == 1 ? "\(title), 1 item" : "\(title), \(count) items")
    }

    /// The hairline stops short of the edge you can see, even when the list's columns run wider than the window.
    override func layout() {
        let visible = visibleRect
        let hidden = visible.isEmpty ? 0 : max(0, bounds.maxX - visible.maxX)
        let wanted = -(trailingInset + hidden)
        if lineTrailing?.constant != wanted { lineTrailing?.constant = wanted }
        super.layout()
    }
    var titleForTesting: String { label.stringValue }

    // A heading is part of the background: clicks, right-clicks, rubber bands and drops go to the view behind it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A grid section's heading.
@MainActor final class GridSectionHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("section-heading")
    let heading = SectionHeadingView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor), heading.trailingAnchor.constraint(equalTo: trailingAnchor),
            heading.topAnchor.constraint(equalTo: topAnchor), heading.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// Under a selected item's whole name, the heading cuts that part away, as the items do.
    func apply(_ layoutAttributes: NSCollectionViewLayoutAttributes) {
        cutAway((layoutAttributes as? GridLayoutAttributes)?.coveredBy ?? .zero, frame: layoutAttributes.frame)
    }
    override func prepareForReuse() { super.prepareForReuse(); cutAway(.zero, frame: frame) }
}

/// The list's item for a heading row. One per kind, kept for the list's life, so AppKit sees the same row.
final class SectionBox: NSObject {
    let kind: ContentSections.Kind
    init(_ kind: ContentSections.Kind) { self.kind = kind }
}

/// A heading row in the list, which spans every column.
@MainActor final class ListSectionHeadingCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("section-heading")
    let heading = SectionHeadingView()
    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor), heading.trailingAnchor.constraint(equalTo: trailingAnchor),
            heading.topAnchor.constraint(equalTo: topAnchor), heading.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
}

/// A heading row draws no fill of its own, selected or not; the list's `floatsGroupRows` keeps it from sticking.
@MainActor final class SectionHeadingRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
}
#endif
