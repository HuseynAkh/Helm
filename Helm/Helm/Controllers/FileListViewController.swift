import Cocoa
import QuickLookUI

class FileListViewController: NSViewController, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    let viewModel: DirectoryViewModel

    var onNavigate: ((URL) -> Void)? {
        didSet { applyCallbacks() }
    }
    var onContextMenu: (([FileItem], URL, NSEvent) -> Void)? {
        didSet { applyCallbacks() }
    }
    var onSelectionChanged: (() -> Void)? {
        didSet { applyCallbacks() }
    }
    var onDirectoryMutated: (() -> Void)? {
        didSet { applyCallbacks() }
    }
    var onOpenItem: ((FileItem) -> Void)? {
        didSet { applyCallbacks() }
    }

    private var gridView: FileGridView?
    private var listView: FileListView?
    private var currentViewMode: ViewMode = .grid

    init(viewModel: DirectoryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        switchViewMode(viewModel.viewMode)
    }

    func switchViewMode(_ mode: ViewMode) {
        currentViewMode = mode

        // Remove current view
        gridView?.removeFromSuperview()
        listView?.removeFromSuperview()

        switch mode {
        case .grid:
            let grid = FileGridView(viewModel: viewModel)
            grid.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(grid)
            pinToEdges(grid)
            gridView = grid
            listView = nil

        case .list:
            let list = FileListView(viewModel: viewModel)
            list.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(list)
            pinToEdges(list)
            listView = list
            gridView = nil
        }

        applyCallbacks()
    }

    func reloadData() {
        gridView?.reloadData()
        listView?.reloadData()
    }

    private func pinToEdges(_ subview: NSView) {
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: view.topAnchor),
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func applyCallbacks() {
        gridView?.onNavigate = onNavigate
        gridView?.onContextMenu = onContextMenu
        gridView?.onSelectionChanged = { [weak self] in
            self?.onSelectionChanged?()
        }
        gridView?.onDirectoryMutated = { [weak self] in
            self?.onDirectoryMutated?()
        }
        gridView?.onOpenItem = onOpenItem

        listView?.onNavigate = onNavigate
        listView?.onContextMenu = onContextMenu
        listView?.onSelectionChanged = { [weak self] in
            self?.onSelectionChanged?()
        }
        listView?.onDirectoryMutated = { [weak self] in
            self?.onDirectoryMutated?()
        }
        listView?.onOpenItem = onOpenItem
    }

    // MARK: - Quick Look

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            toggleQuickLook()
        } else {
            super.keyDown(with: event)
        }
    }

    func toggleQuickLook() {
        guard !viewModel.selectedItems.isEmpty else { return }
        if let panel = QLPreviewPanel.shared() {
            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedFileItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard index < selectedFileItems.count else { return nil }
        return selectedFileItems[index].url as NSURL
    }

    private var selectedFileItems: [FileItem] {
        viewModel.displayItems.filter { viewModel.selectedItems.contains($0.url) }
    }

    #if DEBUG
    func debugHasWiredCallbacks() -> Bool {
        switch currentViewMode {
        case .grid:
            return gridView?.onNavigate != nil &&
                gridView?.onContextMenu != nil &&
                gridView?.onSelectionChanged != nil &&
                gridView?.onDirectoryMutated != nil &&
                gridView?.onOpenItem != nil
        case .list:
            return listView?.onNavigate != nil &&
                listView?.onContextMenu != nil &&
                listView?.onSelectionChanged != nil &&
                listView?.onDirectoryMutated != nil &&
                listView?.onOpenItem != nil
        }
    }
    #endif
}
