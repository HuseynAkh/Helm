import Cocoa

class FileGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {

    var onNavigate: ((URL) -> Void)?
    var onOpenItem: ((FileItem) -> Void)?
    var onContextMenu: (([FileItem], URL, NSEvent) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onDirectoryMutated: (() -> Void)?

    let viewModel: DirectoryViewModel
    private let gridCollectionView: NSCollectionView
    private let scrollView: NSScrollView
    private let iconService = FileIconService.shared

    private static let itemIdentifier = NSUserInterfaceItemIdentifier("FileGridItem")

    init(viewModel: DirectoryViewModel) {
        self.viewModel = viewModel
        self.gridCollectionView = NSCollectionView()
        self.scrollView = NSScrollView()
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 100, height: 100)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        gridCollectionView.collectionViewLayout = layout
        gridCollectionView.dataSource = self
        gridCollectionView.delegate = self
        gridCollectionView.isSelectable = true
        gridCollectionView.allowsMultipleSelection = true
        gridCollectionView.backgroundColors = [.clear]
        gridCollectionView.register(FileGridItemView.self, forItemWithIdentifier: Self.itemIdentifier)

        // Register for drag & drop
        gridCollectionView.registerForDraggedTypes([.fileURL])
        gridCollectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        gridCollectionView.setDraggingSourceOperationMask([.copy], forLocal: false)

        scrollView.documentView = gridCollectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
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
        gridCollectionView.reloadData()
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = gridCollectionView.convert(event.locationInWindow, from: nil)
        let selectedItems: [FileItem]

        if let indexPath = gridCollectionView.indexPathForItem(at: point) {
            if !gridCollectionView.selectionIndexPaths.contains(indexPath) {
                gridCollectionView.deselectAll(nil)
                gridCollectionView.selectItems(at: [indexPath], scrollPosition: [])
            }
            selectedItems = gridCollectionView.selectionIndexPaths.compactMap { ip in
                guard ip.item < viewModel.displayItems.count else { return nil }
                return viewModel.displayItems[ip.item]
            }
        } else {
            gridCollectionView.deselectAll(nil)
            viewModel.selectedItems = Set<URL>()
            onSelectionChanged?()
            selectedItems = []
        }

        onContextMenu?(selectedItems, viewModel.currentURL, event)
        return nil
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        viewModel.displayItems.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: Self.itemIdentifier,
            for: indexPath
        ) as! FileGridItemView

        let fileItem = viewModel.displayItems[indexPath.item]
        item.configure(with: fileItem, iconService: iconService)
        item.onDoubleClick = { [weak self] clickedItem in
            if clickedItem.isDirectory && !clickedItem.isPackage {
                self?.onNavigate?(clickedItem.url)
            } else {
                self?.onOpenItem?(clickedItem)
            }
        }
        return item
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        syncSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        syncSelection()
    }

    private func syncSelection() {
        let urls = gridCollectionView.selectionIndexPaths.compactMap { indexPath -> URL? in
            guard indexPath.item < viewModel.displayItems.count else { return nil }
            return viewModel.displayItems[indexPath.item].url
        }
        viewModel.selectedItems = Set(urls)
        onSelectionChanged?()
    }

    // MARK: - Drag Source

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> (any NSPasteboardWriting)? {
        viewModel.displayItems[indexPath.item].url as NSURL
    }

    // MARK: - Drop Target

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: any NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        let indexPath = proposedDropIndexPath.pointee as IndexPath
        if proposedDropOperation.pointee == .on,
           indexPath.item < viewModel.displayItems.count {
            let target = viewModel.displayItems[indexPath.item]
            if target.isDirectory && !target.isPackage {
                return NSEvent.modifierFlags.contains(.option) ? .copy : .move
            }
        }
        proposedDropOperation.pointee = .before
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return false
        }

        let targetURL: URL
        if dropOperation == .on, indexPath.item < viewModel.displayItems.count {
            let target = viewModel.displayItems[indexPath.item]
            if target.isDirectory && !target.isPackage {
                targetURL = target.url
            } else {
                targetURL = viewModel.currentURL
            }
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

// MARK: - Grid Item View

class FileGridItemView: NSCollectionViewItem {

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let thumbnailService = ThumbnailService.shared
    private var thumbnailRequestKey: String?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(iconView)
        view.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2)
        ])
    }

    func configure(with item: FileItem, iconService: FileIconService) {
        self.fileItem = item
        nameLabel.stringValue = item.name

        // Cancel any previous thumbnail request from a recycled cell
        if let key = thumbnailRequestKey {
            thumbnailService.cancelRequest(for: key)
            thumbnailRequestKey = nil
        }

        let size = NSSize(width: 64, height: 64)

        // Show system icon immediately (synchronous, fast)
        iconView.image = iconService.icon(for: item.url.path, size: size)

        // Check if this file type benefits from a QL thumbnail
        guard thumbnailService.shouldGenerateThumbnail(for: item) else { return }

        // Check cache synchronously first
        if let cached = thumbnailService.cachedThumbnail(for: item.url.path, size: size) {
            iconView.image = cached
            return
        }

        // Generate asynchronously — replace icon when ready
        let itemURL = item.url
        thumbnailRequestKey = thumbnailService.generateThumbnail(for: itemURL, size: size) { [weak self] thumbnail in
            guard let self, self.fileItem?.url == itemURL else { return }
            if let thumbnail {
                self.iconView.image = thumbnail
            }
        }
    }

    override var isSelected: Bool {
        didSet {
            if isSelected {
                view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
                view.layer?.cornerRadius = 8
            } else {
                view.layer?.backgroundColor = nil
            }
        }
    }

    var onDoubleClick: ((FileItem) -> Void)?
    private(set) var fileItem: FileItem?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let fileItem = fileItem {
            onDoubleClick?(fileItem)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let key = thumbnailRequestKey {
            thumbnailService.cancelRequest(for: key)
            thumbnailRequestKey = nil
        }
        iconView.image = nil
        nameLabel.stringValue = ""
        view.layer?.backgroundColor = nil
        fileItem = nil
        onDoubleClick = nil
    }
}
