#if os(macOS)
import AppKit
import HelmCore

/// The list's stand-in row under a folder whose listing is slow to arrive (a network share or a sleepy disk).
/// It isn't a file: it can't be selected, dragged, opened or typed to, and it gives way to the folder's rows.
final class LoadingBox: NSObject {
    let parent: ItemID
    init(parent: ItemID) { self.parent = parent }
}

/// “Loading…” beside a small spinner, set in from the folder like a child row.
@MainActor final class ListLoadingCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("loading")
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Loading…")
    private var spinnerSide: NSLayoutConstraint?
    private var spinnerCenter: NSLayoutConstraint?
    private var labelLeading: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.textColor = .secondaryLabelColor
        for view in [spinner, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let side = spinner.widthAnchor.constraint(equalToConstant: 16)
        let center = spinner.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 13)
        let leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 33)
        spinnerSide = side; spinnerCenter = center; labelLeading = leading
        NSLayoutConstraint.activate([
            center, spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            side, spinner.heightAnchor.constraint(equalTo: spinner.widthAnchor),
            leading, label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Loading")
        // Read once, as "Loading", rather than again for the words and the spinner inside.
        label.cell?.setAccessibilityElement(false)
        spinner.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    func apply(textSize: CGFloat) {
        label.font = .systemFont(ofSize: textSize)
        // The spinner sits in the middle of where a file's icon would, a little smaller, and the words start where file
        // names do, so the rows that take its place land in the same column. The sizes are the name cell's own.
        let icon = ceil(textSize * 1.6)
        spinnerSide?.constant = max(14, ceil(textSize * 1.1))
        spinnerCenter?.constant = 2 + icon / 2
        labelLeading?.constant = 2 + icon + 8
        spinner.startAnimation(nil)
    }
    /// A recycled row stops spinning while it waits off screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }
}
#endif
