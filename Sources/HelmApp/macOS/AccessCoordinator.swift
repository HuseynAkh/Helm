#if os(macOS)
import AppKit
import HelmCore
import HelmPersistence
import HelmUI

/// Full Disk Access across the app: the shared permission, the welcome window and its guide, and trying blocked
/// places again when Helm comes back to the front. A fixture run uses stand-ins for the permission and for moving or
/// restarting Helm, never opens the welcome by itself, and never opens System Settings, copies Helm or relaunches.
/// The same window shows the AI mode screen, which a fixture run never opens by itself either.
///
/// Setup comes before anything macOS guards. While setup is owed, a launch shows the onboarding and holds every window
/// back until it closes (`setUpBeforeWindows`), so macOS asks about no folder before the person has seen it, and the
/// file windows open only once the onboarding is through. AI mode is one of its steps in every onboarding, not a window
/// of its own. Setup is owed until the onboarding has been through once, again whenever another build runs (macOS treats a new build of an
/// ad hoc signed app as a new app and forgets its folder access and Full Disk Access), and while an onboarding that was
/// quit part way is kept: the next launch carries on from its step.
///
/// Once Full Disk Access is switched on, macOS offers Quit & Reopen, since it applies it in full only from the next
/// launch, and the onboarding's step offers Restart Helm, which does the same. Either way the onboarding's next step is
/// kept, and the launch that follows carries on there.
@MainActor final class AccessCoordinator {
    /// Where launch stands with setup: not looked at yet, waiting for the onboarding to close, or through.
    enum LaunchGate { case unchecked, waiting, open }

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
    /// The browser window in front, if any. Done opens the panel there when no window's spark asked.
    private var frontWindow: () -> BrowserWindowController? = { nil }
    private(set) var onboarding: OnboardingWindowController?
    private var activation: NSObjectProtocol?
    private var termination: NSObjectProtocol?
    /// Asked for from the Help menu before launch finished; shown once it has.
    private var pendingRequest: OnboardingModel.Mode?
    /// What a fixture run's welcome window takes VoiceOver to be doing. A scripted run never asks the real Mac.
    var voiceOverForTesting = false
    /// What Settings › AI, the AI mode screen and the onboarding's AI step show, made the first time one is needed.
    var aiSetup: AISetupModel?
    /// Where the onboarding's AI step gets its model: the app's, made the first time it's needed. Nil leaves the step out.
    var aiModel: () -> AISetupModel? = { nil }
    /// What Done does once AI mode ended connected: for the window whose spark opened the AI mode screen, or else for
    /// the window in front.
    var openAgentPanel: (BrowserWindowController) -> Void = { $0.openAgentPanel() }
    /// Lets a test's background run open the AI mode screen by itself at launch, as a person's launch would.
    var opensAIIntroForTesting = false
    /// Where launch stands with setup.
    private(set) var launchGate: LaunchGate = .unchecked
    /// Everything waiting for the onboarding to close before it opens a window.
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    /// Lets a test's background run hold its windows back for setup, as a person's launch does.
    var gatesLaunchForTesting = false

    init(isolated: Bool, interactive: Bool) {
        isIsolated = isolated
        isInteractive = interactive
        privacy = isolated ? MemoryPrivacyAccess() : SystemPrivacyAccess()
        mover = isolated ? MemoryAppMover() : SystemAppMover()
        permissions = PermissionCenter(provider: privacy)
        permissions.presentGuide = { [weak self] pane in self?.showGuide(pane) }
        // Quit & Reopen ends Helm with the onboarding still open: its step is kept, and the next launch carries on there.
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitting() }
        }
    }

    /// Helm is quitting. An open onboarding stays where it got to, for the next launch; nothing counts as seen.
    func quitting() { onboarding?.quitting() }

    /// Checks access before the first window draws, then again whenever Helm comes back to the front, which
    /// is when an answered macOS question or a new permission shows up.
    func start(settings: SettingsStore, fileViewer: @escaping () -> FileViewerModel?, windows: @escaping () -> [BrowserWindowController],
               front: (() -> BrowserWindowController?)? = nil) async {
        self.settings = settings; self.fileViewer = fileViewer; self.windows = windows
        frontWindow = front ?? { windows().first }
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

    // MARK: Setup before any window

    /// Whether this run holds its windows back for setup: one a person sees, or a test that asks. A fixture or
    /// scripted run opens its windows at once, and shows the welcome only when a step asks.
    var launchWaitsForSetup: Bool { (!isIsolated && isInteractive) || gatesLaunchForTesting }

    /// Whether setup is owed: it has never been through, an onboarding was quit part way, or another build saw it last.
    var setupOwed: Bool {
        guard let settings else { return false }
        let snapshot = settings.snapshot
        if !snapshot.bool(.onboardingCompleted) || savedProgress != nil { return true }
        guard let build = privacy.buildIdentity else { return false }
        return snapshot.string(.setupBuild) != build
    }

    /// How far an onboarding that was quit part way got, if one was.
    var savedProgress: OnboardingProgress? {
        settings.flatMap { OnboardingProgress(text: $0.snapshot.string(.setupProgress)) }
    }

    /// Keeps how far the onboarding got, or forgets it with nil.
    private func keepProgress(_ progress: OnboardingProgress?) {
        guard let settings else { return }
        let text = progress?.text ?? ""
        if settings.snapshot.string(.setupProgress) != text { settings.set(.string(text), for: .setupProgress) }
    }

    /// Whether a window asked for now must wait for the onboarding that is on show.
    var windowsWaitForSetup: Bool { launchGate == .waiting }
    /// Whether a window may open straight away: setup is through for this run, or this run doesn't wait for it.
    var windowsMayOpen: Bool { launchGate == .open || (launchGate == .unchecked && !launchWaitsForSetup) }

    /// Every way to a window comes here first. When setup is owed, the onboarding opens, or carries on for a copy that
    /// was just moved into Applications or after a quit, and this returns once it has closed; until then nothing reads a
    /// folder macOS guards and no file window opens. When nothing is owed, or this run doesn't wait, it returns at once.
    /// Later calls return at once too, or wait for the same onboarding.
    func setUpBeforeWindows(continuing rows: [SetupRow]? = nil) async {
        switch launchGate {
        case .open: return
        case .waiting:
            await withCheckedContinuation { gateWaiters.append($0) }
            return
        case .unchecked:
            break
        }
        guard launchWaitsForSetup, settings != nil else { launchGate = .open; return }
        launchGate = .waiting
        showWelcomeIfNeeded(continuing: rows)
        guard onboarding?.isSetupShown == true else { openGate(); return }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    /// The onboarding has gone: the windows waiting for it open.
    private func openGate() {
        guard launchGate != .open else { return }
        launchGate = .open
        let waiting = gateWaiters
        gateWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Once, on the first launch, unless everything is set up already, and again after a quit part way through. A copy
    /// that was just moved into Applications opens it to carry on: with the flag the moving copy gave it, or, opened by
    /// hand, with the rows the move saved. Fixture runs only show the first launch's onboarding when a smoke step asks.
    func showWelcomeIfNeeded(continuing rows: [SetupRow]? = nil) {
        if let rows { continueSetup(rows); return }
        // Only the copy in Applications takes them: one still on the disk image leaves them for it.
        if let saved = carriedRows(), mover.placement == .applications { continueSetup(saved); return }
        guard launchWaitsForSetup else { return }
        openOnFirstLaunch()
    }

    /// The rows the move saved for the copy in Applications, if any are waiting.
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

    /// Whether AI mode has been seen, on the onboarding's AI step or its own screen. Every onboarding has the AI step;
    /// once it has been seen, it's no reason on its own to open a launch's onboarding.
    private var aiSeen: Bool { settings?.snapshot.bool(.aiIntroSeen) ?? true }

    /// A launch's onboarding: the first launch's, another build's, or one that was quit part way, which carries on from
    /// its step. Only the steps left to do show; if none is, there's nothing to show, and that counts as through.
    func openOnFirstLaunch() {
        guard settings != nil, setupOwed else { return }
        let controller = onboarding ?? makeOnboarding()
        guard !controller.isShown else { return }
        if !controller.showSetup(resuming: savedProgress, aiSeen: aiSeen, activate: isInteractive) { markWelcomeSeen() }
    }

    func continueSetup(_ rows: [SetupRow]) {
        guard settings != nil else { return }
        // Handed over now, so they aren't carried on twice.
        saveCarried(nil)
        (onboarding ?? makeOnboarding()).continueSetup(rows, resuming: savedProgress, activate: isInteractive)
    }

    func showWelcome() { present(.setup) }

    /// Full Disk Access gets the guide. macOS already lists Helm under the other rows once it has asked, so those open directly.
    func showGuide(_ pane: PrivacyPane) {
        if pane == .fullDiskAccess { present(.guide) } else { permissions.open(pane) }
    }

    /// The onboarding holds the windows back and something asked for one, as a click on the Dock icon does: it comes to
    /// the front as it is.
    func bringSetupForward() {
        onboarding?.bringForward(activate: isInteractive)
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
        controller.model.aiSource = { [weak self] in self?.aiModel() }
        controller.onSeen = { [weak self] in self?.markWelcomeSeen() }
        controller.onCarry = { [weak self] rows in self?.saveCarried(rows) }
        controller.onProgress = { [weak self] progress in self?.keepProgress(progress) }
        controller.onClosed = { [weak self] _ in self?.onboardingClosed() }
        controller.onRestart = { [weak self] in self?.restartHelm() }
        onboarding = controller
        return controller
    }

    /// The onboarding has been through, by this build: it opens by itself again only for another build. Where it got to
    /// is forgotten, and so is the AI mode screen's launch: AI mode was one of its steps, or the person closed it first,
    /// and nothing comes up by itself after it.
    private func markWelcomeSeen() {
        guard let settings else { return }
        if !settings.snapshot.bool(.onboardingCompleted) { settings.set(.bool(true), for: .onboardingCompleted) }
        if let build = privacy.buildIdentity, settings.snapshot.string(.setupBuild) != build {
            settings.set(.string(build), for: .setupBuild)
        }
        keepProgress(nil)
        if !settings.snapshot.bool(.aiIntroSeen) { settings.set(.bool(true), for: .aiIntroSeen) }
    }

    // MARK: The AI mode screen

    /// Shows the AI mode screen in the welcome window. When it ends connected, Done opens the panel: in `window`, whose
    /// spark opened it, or else in the window in front. While the onboarding is open, it goes to its AI step instead.
    func showAIMode(_ model: AISetupModel, from window: BrowserWindowController?) {
        guard settings != nil else { return }
        let controller = onboarding ?? makeOnboarding()
        controller.showAIMode(model, activate: isInteractive) { [weak self, weak window] connected in
            guard connected, let self else { return }
            guard let target = window ?? self.frontWindow() ?? self.windows().first else { return }
            self.openAgentPanel(target)
        }
    }

    /// For someone who set Helm up before AI mode existed and gets no onboarding at this launch: the AI mode screen,
    /// once, and only once their window is up. A launch with an onboarding has AI mode as one of its steps, so nothing
    /// comes up after it. Never by itself in a fixture run or a scripted one.
    func showAIIntroIfNeeded(_ model: () -> AISetupModel?) {
        guard (!isIsolated && isInteractive) || opensAIIntroForTesting, let settings,
              settings.snapshot.bool(.onboardingCompleted), !settings.snapshot.bool(.aiIntroSeen),
              onboarding?.isShown != true, !windows().isEmpty, let model = model() else { return }
        showAIMode(model, from: nil)
    }

    private func onboardingClosed() {
        if launchGate == .waiting { openGate() }
    }

    /// Restart Helm, from the onboarding's Full Disk Access step once access is on. The onboarding has kept its next
    /// step, so the launch that follows carries on there. A fixture run's mover only counts it, and the relaunch is
    /// stood in for in this process.
    private func restartHelm() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let quit = await self.mover.restart()
            // Still running: the quit was cancelled, or this is a fixture run, whose mover never quits.
            guard !quit, self.isIsolated else { return }
            await self.quitAndReopenForTesting()
        }
    }

    /// Settings › General › Access.
    var settingsSection: AccessSettings {
        AccessSettings(permissions: permissions, setUp: { [weak self] in self?.showGuide(.fullDiskAccess) },
                       showWelcome: { [weak self] in self?.showWelcome() })
    }

    // MARK: Standing in for a relaunch

    /// What macOS's Quit & Reopen and Restart Helm do, in one process: Helm quits as it would (`quitting`, then the
    /// window goes with the process, counting nothing), `meanwhile` runs, as macOS applies a new Full Disk Access only to
    /// the next launch, and that launch reads Full Disk Access again and shows what setup is owed. A scripted run or a
    /// test stands in for the relaunch with this; nothing quits.
    func quitAndReopenForTesting(meanwhile: () -> Void = {}) async {
        quitting()
        onboarding?.endWithProcess()
        onboarding = nil
        meanwhile()
        permissions.relaunchedForTesting()
        await permissions.refresh()
        openOnFirstLaunch()
    }
}
#endif
