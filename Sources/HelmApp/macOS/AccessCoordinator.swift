#if os(macOS)
import AppKit
import HelmCore
import HelmPersistence
import HelmUI

/// Full Disk Access across the app: the shared permission, the welcome window and its guide, and trying blocked
/// places again when Helm comes back to the front. A fixture run uses stand-ins for the permission and for moving Helm
/// into Applications, never opens the welcome by itself, and never opens System Settings, copies Helm or relaunches.
@MainActor final class AccessCoordinator {
    let privacy: any PrivacyAccessProviding
    let permissions: PermissionCenter
    let mover: any AppMoving
    private let isIsolated: Bool
    /// False for scripted runs and tests, which stay in the background: the welcome window is then invisible and never
    /// brings Helm forward. Set before the window is first made.
    var isInteractive: Bool
    private var settings: SettingsStore?
    private var fileViewer: () -> FileViewerModel? = { nil }
    private var windows: () -> [BrowserWindowController] = { [] }
    private(set) var onboarding: OnboardingWindowController?
    private var activation: NSObjectProtocol?
    private var termination: NSObjectProtocol?
    /// Asked for from the Help menu before launch finished; shown once it has.
    private var pendingRequest: OnboardingModel.Mode?
    /// What a fixture run's welcome window takes VoiceOver to be doing. A scripted run never asks the real Mac.
    var voiceOverForTesting = false

    init(isolated: Bool, interactive: Bool) {
        isIsolated = isolated
        isInteractive = interactive
        privacy = isolated ? MemoryPrivacyAccess() : SystemPrivacyAccess()
        mover = isolated ? MemoryAppMover() : SystemAppMover()
        permissions = PermissionCenter(provider: privacy)
        permissions.presentGuide = { [weak self] pane in self?.showGuide(pane) }
        // Quit & Reopen ends Helm with the welcome still open; it mustn't open again on the next launch.
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitting() }
        }
    }

    /// Helm is quitting: an open welcome counts as seen.
    func quitting() { onboarding?.quitting() }

    /// Checks access before the first window draws, then again whenever Helm comes back to the front, which
    /// is when an answered macOS question or a new permission shows up.
    func start(settings: SettingsStore, fileViewer: @escaping () -> FileViewerModel?, windows: @escaping () -> [BrowserWindowController]) async {
        self.settings = settings; self.fileViewer = fileViewer; self.windows = windows
        await permissions.refresh()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
        if let request = pendingRequest { pendingRequest = nil; present(request) }
    }

    private func becameActive() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.permissions.refresh()
            for window in self.windows() { window.retryBlockedLoads() }
        }
    }

    /// Once, on the first launch, unless everything is set up already. A copy that was just moved into Applications
    /// opens it again to carry on: with the flag the moving copy gave it, or, opened by hand, with the rows Set Up saved.
    /// Fixture runs only show the first launch's welcome when a smoke step asks.
    func showWelcomeIfNeeded(continuing rows: [SetupRow]? = nil) {
        if let rows { continueSetup(rows); return }
        // Only the copy in Applications takes them: one still on the disk image leaves them for it.
        if let saved = carriedRows(), mover.placement == .applications { continueSetup(saved); return }
        guard !isIsolated, isInteractive else { return }
        openOnFirstLaunch()
    }

    /// The rows Set Up saved for the copy in Applications, if any are waiting.
    private func carriedRows() -> [SetupRow]? {
        guard let text = settings?.snapshot.string(.setupCarriedRows), !text.isEmpty else { return nil }
        return SetupRow.rows(fromFlag: text)
    }

    /// Saves the rows for the copy in Applications, or clears them with nil.
    private func saveCarried(_ rows: [SetupRow]?) {
        guard let settings else { return }
        let text = rows.map { $0.map(\.rawValue).joined(separator: ",") } ?? ""
        if settings.snapshot.string(.setupCarriedRows) != text { settings.set(.string(text), for: .setupCarriedRows) }
    }

    /// The first launch's welcome. If every row is already done there's nothing to show, and that counts as seen.
    func openOnFirstLaunch() {
        guard let settings, !settings.snapshot.bool(.onboardingCompleted) else { return }
        let controller = onboarding ?? makeOnboarding()
        guard !controller.isShown else { return }
        controller.model.begin(.setup)
        if controller.model.nothingToDo { markWelcomeSeen(); return }
        controller.show(.setup, activate: isInteractive)
    }

    func continueSetup(_ rows: [SetupRow]) {
        guard settings != nil else { return }
        // Handed over now, so they aren't carried on twice.
        saveCarried(nil)
        (onboarding ?? makeOnboarding()).continueSetup(rows, activate: isInteractive)
    }

    func showWelcome() { present(.setup) }

    /// Full Disk Access gets the guide. macOS already lists Helm under the other rows once it has asked, so those open directly.
    func showGuide(_ pane: PrivacyPane) {
        if pane == .fullDiskAccess { present(.guide) } else { permissions.open(pane) }
    }

    private func present(_ mode: OnboardingModel.Mode) {
        guard settings != nil else { pendingRequest = mode; return }
        (onboarding ?? makeOnboarding()).show(mode, activate: isInteractive)
    }

    private func makeOnboarding() -> OnboardingWindowController {
        let controller = OnboardingWindowController(permissions: permissions, fileViewer: fileViewer(), mover: mover)
        // A scripted run's windows stay invisible and out of the way, this one included, from before it first shows.
        if !isInteractive { SmokeBackground.hide(controller.window) }
        if isIsolated { controller.model.isVoiceOverRunning = { [weak self] in self?.voiceOverForTesting ?? false } }
        controller.onSeen = { [weak self] in self?.markWelcomeSeen() }
        controller.onCarry = { [weak self] rows in self?.saveCarried(rows) }
        onboarding = controller
        return controller
    }

    /// The welcome opens by itself only until it's been seen.
    private func markWelcomeSeen() {
        guard let settings, !settings.snapshot.bool(.onboardingCompleted) else { return }
        settings.set(.bool(true), for: .onboardingCompleted)
    }

    /// Settings › General › Access.
    var settingsSection: AccessSettings {
        AccessSettings(permissions: permissions, setUp: { [weak self] in self?.showGuide(.fullDiskAccess) },
                       showWelcome: { [weak self] in self?.showWelcome() })
    }
}
#endif
