import Cocoa
import SwiftUI

class SidebarContainerController: NSViewController {

    var onPlaceSelected: ((URL) -> Void)?

    private var placesHostingController: NSHostingController<SidebarPlacesView>?
    private var glassBackgroundView: NSVisualEffectView?
    private var userDefaultsObserver: NSObjectProtocol?

    private let sidebarViewModel = SidebarViewModel()

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupPlacesView()
        applyAppearance()
        observeSettingsChanges()
    }

    deinit {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
    }

    private func setupPlacesView() {
        sidebarViewModel.onPlaceSelected = { [weak self] url in
            self?.onPlaceSelected?(url)
        }

        let placesView = SidebarPlacesView(viewModel: sidebarViewModel)
        let hostingController = NSHostingController(rootView: placesView)
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        placesHostingController = hostingController
    }

    func selectLocation(_ url: URL) {
        sidebarViewModel.selectLocation(url)
    }

    private func observeSettingsChanges() {
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
    }

    private func applyAppearance() {
        guard let contentView = placesHostingController?.view else { return }

        if AppSettings.sidebarLiquidGlassEnabled {
            let glassView: NSVisualEffectView
            if let existing = glassBackgroundView {
                glassView = existing
            } else {
                let created = NSVisualEffectView()
                created.translatesAutoresizingMaskIntoConstraints = false
                created.blendingMode = .withinWindow
                created.state = .active
                view.addSubview(created, positioned: .below, relativeTo: contentView)
                NSLayoutConstraint.activate([
                    created.topAnchor.constraint(equalTo: view.topAnchor),
                    created.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    created.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    created.bottomAnchor.constraint(equalTo: view.bottomAnchor)
                ])
                glassBackgroundView = created
                glassView = created
            }

            glassView.isHidden = false
            glassView.material = .sidebar
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            glassBackgroundView?.isHidden = true
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}
