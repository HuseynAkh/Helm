import Cocoa

class FileListView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {

    var onNavigate: ((URL) -> Void)?
    var onOpenItem: ((FileItem) -> Void)?
    var onContextMenu: (([FileItem], URL, NSEvent) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onDirectoryMutated: (() -> Void)?

    private let viewModel: DirectoryViewModel
    private let outlineView: NSOutlineView
    private let scrollView: NSScrollView
    private let fileSystemService = FileSystemService()
    private let iconService = FileIconService.shared
    private let thumbnailService = ThumbnailService.shared

    // Cache for expanded directory children
    private var childrenCache: [URL: [FileItem]] = [:]

    init(viewModel: DirectoryViewModel) {
        self.viewModel = viewModel
        self.outlineView = NSOutlineView()
        self.scrollView = NSScrollView()
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        // Name column
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.minWidth = 200
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn

        // Size column
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 80
        sizeColumn.minWidth = 60
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        outlineView.addTableColumn(sizeColumn)

        // Date Modified column
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dateModified"))
        dateColumn.title = "Date Modified"
        dateColumn.width = 160
        dateColumn.minWidth = 100
        dateColumn.sortDescriptorPrototype = NSSortDescriptor(key: "dateModified", ascending: true)
        outlineView.addTableColumn(dateColumn)

        // Kind column
        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.title = "Kind"
        kindColumn.width = 120
        kindColumn.minWidth = 80
        outlineView.addTableColumn(kindColumn)

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowHeight = 24
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.style = .fullWidth
        outlineView.doubleAction = #selector(doubleClickAction)
        outlineView.target = self

        // Register for drag & drop
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outlineView.setDraggingSourceOperationMask([.copy], forLocal: false)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func reloadData() {
        childrenCache.removeAll()
        outlineView.reloadData()
    }

    @objc private func doubleClickAction() {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? FileItem else { return }

        if item.isDirectory && !item.isPackage {
            onNavigate?(item.url)
        } else {
            onOpenItem?(item)
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return viewModel.displayItems.count
        }

        guard let fileItem = item as? FileItem,
              fileItem.isDirectory && !fileItem.isPackage else {
            return 0
        }

        if let cached = childrenCache[fileItem.url] {
            return cached.count
        }

        // Load children asynchronously
        Task { @MainActor in
            do {
                let children = try await fileSystemService.contentsOfDirectory(at: fileItem.url)
                childrenCache[fileItem.url] = FileItemSort.defaultSort.sorted(children)
                outlineView.reloadItem(fileItem, reloadChildren: true)
            } catch {
                childrenCache[fileItem.url] = []
            }
        }

        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return viewModel.displayItems[index]
        }

        if let fileItem = item as? FileItem, let children = childrenCache[fileItem.url],
           index < children.count {
            return children[index]
        }

        // Fallback: return a placeholder. This should not happen in practice since
        // numberOfChildrenOfItem gates the count, but guards against race conditions.
        return viewModel.displayItems.isEmpty
            ? FileItem(id: URL(fileURLWithPath: "/"), url: URL(fileURLWithPath: "/"),
                        name: "", isDirectory: false, isSymlink: false, isHidden: true,
                        size: 0, modificationDate: .distantPast, creationDate: .distantPast,
                        contentType: nil, isPackage: false, isStarred: false)
            : viewModel.displayItems[min(index, viewModel.displayItems.count - 1)]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let fileItem = item as? FileItem else { return false }
        return fileItem.isDirectory && !fileItem.isPackage
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let fileItem = item as? FileItem, let column = tableColumn else { return nil }

        let cellIdentifier = NSUserInterfaceItemIdentifier("Cell-\(column.identifier.rawValue)")

        switch column.identifier.rawValue {
        case "name":
            return makeNameCell(cellIdentifier: cellIdentifier, fileItem: fileItem)
        case "size":
            return makeTextCell(cellIdentifier: cellIdentifier, text: fileItem.isDirectory ? "--" : FileSizeFormatter.format(fileItem.size))
        case "dateModified":
            return makeTextCell(cellIdentifier: cellIdentifier, text: formatDate(fileItem.modificationDate))
        case "kind":
            return makeTextCell(cellIdentifier: cellIdentifier, text: fileItem.contentType?.localizedDescription ?? "")
        default:
            return nil
        }
    }

    private func makeNameCell(cellIdentifier: NSUserInterfaceItemIdentifier, fileItem: FileItem) -> NSTableCellView {
        let cell: FileNameCellView

        if let existingCell = outlineView.makeView(withIdentifier: cellIdentifier, owner: self) as? FileNameCellView {
            cell = existingCell
            // Cancel previous thumbnail request from recycled cell
            if let key = cell.thumbnailRequestKey {
                thumbnailService.cancelRequest(for: key)
                cell.thumbnailRequestKey = nil
            }
        } else {
            cell = FileNameCellView()
            cell.identifier = cellIdentifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.font = NSFont.systemFont(ofSize: 13)
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        let size = NSSize(width: 18, height: 18)
        cell.currentURL = fileItem.url
        cell.textField?.stringValue = fileItem.name
        cell.imageView?.image = iconService.icon(for: fileItem.url.path, size: size)

        // Async thumbnail for eligible file types
        if thumbnailService.shouldGenerateThumbnail(for: fileItem) {
            if let cached = thumbnailService.cachedThumbnail(for: fileItem.url.path, size: size) {
                cell.imageView?.image = cached
            } else {
                let itemURL = fileItem.url
                cell.thumbnailRequestKey = thumbnailService.generateThumbnail(for: itemURL, size: size) { [weak cell] thumbnail in
                    guard let cell, cell.currentURL == itemURL, let thumbnail else { return }
                    cell.imageView?.image = thumbnail
                }
            }
        }

        return cell
    }

    private func makeTextCell(cellIdentifier: NSUserInterfaceItemIdentifier, text: String) -> NSTableCellView {
        let cell: NSTableCellView

        if let existingCell = outlineView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView {
            cell = existingCell
        } else {
            cell = NSTableCellView()
            cell.identifier = cellIdentifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.font = NSFont.systemFont(ofSize: 12)
            textField.textColor = .secondaryLabelColor
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.textField?.stringValue = text
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let selectedRows = outlineView.selectedRowIndexes
        let urls = selectedRows.compactMap { (outlineView.item(atRow: $0) as? FileItem)?.url }
        viewModel.selectedItems = Set(urls)
        onSelectionChanged?()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func formatDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = outlineView.convert(event.locationInWindow, from: nil)
        let row = outlineView.row(at: point)
        let selectedItems: [FileItem]

        if row >= 0 {
            if !outlineView.selectedRowIndexes.contains(row) {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            selectedItems = outlineView.selectedRowIndexes.compactMap {
                outlineView.item(atRow: $0) as? FileItem
            }
        } else {
            outlineView.deselectAll(nil)
            viewModel.selectedItems = Set<URL>()
            onSelectionChanged?()
            selectedItems = []
        }

        onContextMenu?(selectedItems, viewModel.currentURL, event)
        return nil
    }

    // MARK: - Drag Source

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let fileItem = item as? FileItem else { return nil }
        return fileItem.url as NSURL
    }

    // MARK: - Drop Target

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        if let fileItem = item as? FileItem, fileItem.isDirectory && !fileItem.isPackage {
            return NSEvent.modifierFlags.contains(.option) ? .copy : .move
        }
        // Drop on background
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return false
        }

        let targetURL: URL
        if let fileItem = item as? FileItem, fileItem.isDirectory && !fileItem.isPackage {
            targetURL = fileItem.url
        } else {
            targetURL = viewModel.currentURL
        }

        let isCopy = NSEvent.modifierFlags.contains(.option)
        let fileOpService = FileOperationService()

        Task { @MainActor in
            do {
                if isCopy {
                    _ = try await fileOpService.copyItems(urls, to: targetURL)
                } else {
                    _ = try await fileOpService.moveItems(urls, to: targetURL)
                }
                onDirectoryMutated?()
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }

        return true
    }
}

private class FileNameCellView: NSTableCellView {
    var currentURL: URL?
    var thumbnailRequestKey: String?
}
