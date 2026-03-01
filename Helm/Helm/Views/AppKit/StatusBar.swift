import Cocoa

class StatusBar: NSView {

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1)
        ])
    }

    func update(itemCount: Int, selectedCount: Int, url: URL) {
        var parts: [String] = []

        let itemText = itemCount == 1 ? "1 item" : "\(itemCount) items"
        parts.append(itemText)

        if selectedCount > 0 {
            let selectedText = selectedCount == 1 ? "1 selected" : "\(selectedCount) selected"
            parts.append(selectedText)
        }

        // Disk space
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage {
            parts.append("\(FileSizeFormatter.format(Int64(available))) free")
        }

        label.stringValue = parts.joined(separator: "  \u{2022}  ")
    }
}
