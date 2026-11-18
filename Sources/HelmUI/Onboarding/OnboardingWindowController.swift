#if os(macOS)
import AppKit
import Combine
import HelmAgent
import HelmCore
import SwiftUI

/// The welcome window: the onboarding, step by step and every step the same size, on first launch and again from Help or
/// Settings. As the guide it holds only the Full Disk Access row. While that row waits, Full Disk Access is checked
/// every moment, and while System Settings is in front the window stays above it, so Helm's icon can be dragged across.
/// On its own, it shows the AI mode screen, dark, whose Done is the only way to leave AI mode on.
///
/// Quitting with the onboarding open, as macOS's Quit & Reopen and Restart Helm do once Full Disk Access is switched on,
/// changes nothing: the step it reached is kept as it goes (`onProgress`), and the next launch carries on there.
@MainActor public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    public let model: OnboardingModel
    /// Called once the onboarding (not the guide or the AI mode screen) has been through: Get Started, or the window
    /// closed. At most once each time it opens. Quitting with it open doesn't count, so the next launch carries on.
    public var onSeen: (() -> Void)?
    /// Saves (or, with nil, clears) the rows the copy in Applications carries on with. The app keeps them in its settings.
    public var onCarry: (([SetupRow]?) -> Void)?
    /// Keeps how far the onboarding got, each time it moves. The app keeps it in its settings.
    public var onProgress: ((OnboardingProgress) -> Void)?
    /// Called after the window closes, with the mode it was in. The windows the first launch held back open then.
    public var onClosed: ((OnboardingModel.Mode) -> Void)?
    /// Restart Helm, on the Full Disk Access step once access is on: quits Helm and opens it again. The onboarding's
    /// next step is kept first. The app sets it.
    public var onRestart: (() -> Void)?
    private let host: NSHostingController<OnboardingView>
    private var counted = false
    private var isWatching = false
    /// Open, whether on screen or hidden along with Helm (Command-H). A hidden window isn't visible, but it's still
    /// open: asking for it again keeps what it's doing.
    private var isOpen = false
    /// The person asked for the window to close, with its close button, Command-W or Escape. Only their close, or Get
    /// Started, counts as going through the onboarding: a close Helm or AppKit makes, on the way out say, doesn't.
    private var closedByPerson = false
    /// Shown for someone to use, rather than by a scripted run in the background.
    private var interactive = false
    /// The app in front, which decides whether the window floats.
    private var frontmost: String?
    private var subscription: Broadcast<PrivacyAccessStatus>.Token?
    private var activation: NSObjectProtocol?
    private var helmActivation: NSObjectProtocol?
    private var redraw: AnyCancellable?
    /// What Done on the AI mode screen tells the app: whether AI mode ended connected.
    private var aiDone: ((Bool) -> Void)?
    /// Done is closing the window, so the close isn't a way out that turns AI mode off.
    private var closingByDone = false
    /// Done was pressed and is waiting on the model.
    private(set) var aiDoneWork: Task<Void, Never>?
    /// The window is going because the process is, so nothing counts as seen and nothing is turned off.
    private var ending = false

    public init(permissions: PermissionCenter, fileViewer: FileViewerModel?, mover: (any AppMoving)? = nil) {
        model = OnboardingModel(permissions: permissions, fileViewer: fileViewer, mover: mover)
        host = NSHostingController(rootView: OnboardingView(model: model))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // Nothing about this window is worth saving between launches.
        window.isRestorable = false
        window.isMovableByWindowBackground = true
        // Shown again, it comes to the Space the person is on now, rather than the one where it was shown last (as the AI
        // mode screen, say), where it would open out of sight behind Helm's other windows.
        window.collectionBehavior.insert(.moveToActiveSpace)
        super.init(window: window)
        window.delegate = self
        model.close = { [weak self] in self?.close() }
        model.seen = { [weak self] in self?.markSeen() }
        model.changed = { [weak self] in self?.update() }
        model.carry = { [weak self] rows in self?.onCarry?(rows) }
        model.saveProgress = { [weak self] progress in self?.onProgress?(progress) }
        model.restart = { [weak self] in self?.onRestart?() }
        // The standard refusal, so Continue never seems to do nothing. Scripted runs stay quiet.
        model.refused = { [weak self] in if self?.interactive == true { NSSound.beep() } }
        model.announce = { [weak self] text in self?.post(text) }
        subscription = permissions.changes.subscribe { [weak self] _ in self?.model.permissionsChanged() }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                      object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let identifier = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.frontmost = identifier
                self?.update()
            }
        }
        // Helm back in front: the file viewer or the Dock may have changed meanwhile, from Settings, Terminal or the Dock.
        helmActivation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isOpen == true { self?.model.refresh() } }
        }
        // The window fits what it shows: a row that opens up makes it taller, keeping its top edge where it was.
        redraw = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fit() } }
        }
        fit()
        window.center()
    }
    required init?(coder: NSCoder) { nil }

    /// `activate` brings Helm forward; a scripted run leaves whatever you're doing in front. Asked for while it's open,
    /// it keeps what it's doing: the guide turns into the onboarding at its Full Disk Access step, still waiting, and the
    /// onboarding asked for the guide goes to that step, with Helm's icon to drag. Either way it no longer moves on or
    /// closes by itself.
    public func show(_ mode: OnboardingModel.Mode, activate: Bool) {
        // The AI mode screen gives way to the onboarding or the guide. Leaving it so isn't Done.
        if isOpen && model.mode == .ai {
            leaveAIMode()
            counted = false
            model.begin(mode)
            present(activate: activate)
            return
        }
        if !isOpen {
            start { $0.begin(mode) }
        } else {
            model.askedForAgain()
            if mode == .setup { model.switchToSetup() } else { model.requestAccessHelp() }
        }
        present(activate: activate)
    }

    /// A launch's onboarding: from the step where it stopped, or the steps still to do. False, and nothing shows, when
    /// nothing is left to do. AI mode's step is always among them, but once AI mode has been seen (`aiSeen`) it's no
    /// reason on its own to open one.
    public func showSetup(resuming saved: OnboardingProgress?, aiSeen: Bool, activate: Bool) -> Bool {
        if isOpen && model.mode == .ai { leaveAIMode() }
        start { model in
            if let saved { model.resume(saved) } else { model.startSetup(steps: model.plannedSteps(skippingDone: true)) }
        }
        guard !model.nothingLeft(besides: aiSeen && saved == nil ? [.ai] : []) else { return false }
        present(activate: activate)
        return true
    }

    /// Brings the open window to the front as it is, as a click on the Dock icon does while it holds the windows back.
    public func bringForward(activate: Bool) {
        guard isOpen else { return }
        present(activate: activate)
    }

    /// The AI mode screen, drawn from `ai`. Done closes it when the switch is off or the provider is connected, and then
    /// calls `onDone` with whether it ended connected. Closing it any other way turns AI mode off. Asked for while the
    /// onboarding is open, it's the onboarding's AI step instead.
    public func showAIMode(_ ai: AISetupModel, activate: Bool, onDone: @escaping (Bool) -> Void) {
        if isOpen && model.mode == .setup {
            model.showAIStep(ai)
            present(activate: activate)
            return
        }
        if isOpen && model.mode == .ai && model.aiSetup === ai {
            aiDone = onDone
            present(activate: activate)
            return
        }
        if isOpen && model.mode == .ai { leaveAIMode() }
        aiDone = onDone
        start { $0.beginAI(ai) }
        ai.donePressed = { [weak self] key in self?.pressDone(pendingKey: key) }
        present(activate: activate)
    }

    /// Done: commits a typed key, then closes if the model says the screen may.
    private func pressDone(pendingKey: String?) {
        guard aiDoneWork == nil, let ai = model.aiSetup else { return }
        aiDoneWork = Task { @MainActor [weak self] in
            let leaves = await ai.done(pendingKey: pendingKey)
            guard let self else { return }
            self.aiDoneWork = nil
            // The standard refusal, so Done never seems to do nothing. Scripted runs stay quiet.
            if !leaves, self.interactive { NSSound.beep() }
            guard leaves, self.isOpen, self.model.mode == .ai, self.model.aiSetup === ai else { return }
            let connected = ai.isOn && ai.isConnected
            let done = self.aiDone
            self.aiDone = nil
            self.closingByDone = true
            self.close()
            self.closingByDone = false
            done?(connected)
        }
    }

    /// The AI mode screen is left some way other than Done: AI mode goes off.
    private func leaveAIMode() {
        guard model.mode == .ai else { return }
        aiDone = nil
        aiDoneWork?.cancel(); aiDoneWork = nil
        model.aiSetup?.donePressed = nil
        model.aiSetup?.closedWithoutDone()
    }

    /// The copy that was just moved into Applications opens the onboarding again and carries on after the welcome step.
    public func continueSetup(_ rows: [SetupRow], resuming saved: OnboardingProgress? = nil, activate: Bool) {
        if isOpen && model.mode == .ai { leaveAIMode() }
        start { $0.continueSetup(rows, resuming: saved) }
        present(activate: activate)
    }

    private func start(_ body: (OnboardingModel) -> Void) {
        counted = false
        // Shown anew in a process that's going on, after a cancelled quit or a stand-in for one: a close counts again.
        ending = false
        closedByPerson = false
        body(model)
    }

    private func present(activate: Bool) {
        isOpen = true
        interactive = activate
        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        updateTitle()
        // The AI mode screen is always dark; the onboarding, its AI step included, follows the Mac.
        window?.appearance = model.mode == .ai ? NSAppearance(named: .darkAqua) : nil
        // Live status: the file viewer and the Dock are read again, in case they changed while the window was away.
        model.refresh()
        fit()
        // Always the key window, in front of Helm's other windows, as Settings is, so ⌘W and Close act on it. Only ordered
        // in front of every app, it stayed on the Space where it was last shown. Only a person's run brings Helm forward;
        // a scripted one leaves whatever is in front there.
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate(ignoringOtherApps: true) }
        update()
        // So is Full Disk Access, quietly.
        Task { @MainActor [weak self] in await self?.model.permissions.refresh() }
    }

    /// The window's title, which VoiceOver reads: the step's in the onboarding.
    private func updateTitle() {
        switch model.mode {
        case .setup: window?.title = model.step.title
        case .guide: window?.title = "Full Disk Access"
        case .ai: window?.title = AgentText.aiTitle
        }
    }

    /// Open, even while Helm is hidden.
    public var isShown: Bool { isOpen }
    /// The onboarding is open, rather than the guide or the AI mode screen on its own.
    public var isSetupShown: Bool { isOpen && model.mode == .setup }

    /// Helm is quitting. The onboarding is left as it is: the step it reached is kept already, so the next launch
    /// carries on there, as after macOS's Quit & Reopen. Nothing counts as seen, even if the window is closed on the
    /// way out. The AI mode screen on its own is left some way other than Done, so AI mode goes off.
    public func quitting() {
        if isOpen && model.mode == .ai { leaveAIMode() }
        ending = true
    }

    /// Helm has been asked to quit and may yet go: until `cancelEnding`, a close counts nothing.
    public func beginEnding() { ending = true }
    /// The quit was cancelled, so a close counts again.
    public func cancelEnding() { ending = false }

    /// The process ends with the window open, as when macOS quits Helm to reopen it: the window goes with nothing
    /// counted as seen and nothing turned off. Scripted runs and tests stand in for the end of the process with this.
    public func endWithProcess() {
        guard isOpen else { return }
        ending = true
        close()
    }

    private func markSeen() {
        guard model.mode == .setup, !counted else { return }
        counted = true
        onSeen?()
    }

    /// What the window says to VoiceOver: a row that's done or didn't work, and that everything is set up.
    private func post(_ text: String) {
        guard isOpen else { return }
        let element: Any = window.map { $0 as Any } ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Watches for access only while the window waits for it, and floats only while that helps.
    private func update() {
        if model.mode == .setup { updateTitle() }
        let waiting = isOpen && model.isWaitingForAccess
        if waiting != isWatching {
            isWatching = waiting
            model.permissions.watch(waiting)
        }
        window?.level = Self.level(waitingForAccess: waiting, interactive: interactive,
                                   hasAccess: model.permissions.fullDiskAccess == .granted, frontmost: frontmost)
    }

    private func fit() {
        guard let window, let content = window.contentView else { return }
        // Every step of the onboarding is the same size below the title bar, which the content runs under and whose
        // height changes with the SDK Helm is built with: sized without it, a step ran past the window's bottom edge
        // and took its buttons with it. The guide and the AI mode screen fit what they show, title bar included.
        let titleBar = max(0, window.frame.height - window.contentLayoutRect.height)
        let height = model.mode == .setup ? OnboardingView.stepHeight + titleBar
            : ceil(host.sizeThatFits(in: NSSize(width: OnboardingView.width, height: 4000)).height)
        guard height > 0, abs(content.frame.height - height) > 0.5 || abs(content.frame.width - OnboardingView.width) > 0.5 else { return }
        // The top edge stays where it is and the bottom slides, rather than the window snapping to its new size.
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: OnboardingView.width, height: height))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        // Growing downwards mustn't take the buttons off the bottom of the screen.
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame { frame.origin.y = max(frame.origin.y, screen.minY) }
        let animates = interactive && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame, display: true, animate: animates)
    }

    static let systemSettings = "com.apple.systempreferences"
    /// The window floats only while System Settings is in front and Full Disk Access is still off, so Helm's icon can
    /// be dragged into its list. Otherwise it's an ordinary window, which other apps cover as usual.
    static func level(waitingForAccess: Bool, interactive: Bool, hasAccess: Bool, frontmost: String?) -> NSWindow.Level {
        waitingForAccess && interactive && !hasAccess && frontmost == systemSettings ? .floating : .normal
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !ending { closedByPerson = true }
        return true
    }

    public func windowWillClose(_ notification: Notification) {
        let mode = model.mode
        let byPerson = closedByPerson
        closedByPerson = false
        if ending {
            isOpen = false
            if isWatching { isWatching = false; model.permissions.watch(false) }
            model.ended()
            window?.level = .normal
            return
        }
        if mode == .ai && !closingByDone { leaveAIMode() }
        isOpen = false
        if isWatching { isWatching = false; model.permissions.watch(false) }
        model.closed()
        window?.level = .normal
        if byPerson { markSeen() }
        if let onClosed { DispatchQueue.main.async { MainActor.assumeIsolated { onClosed(mode) } } }
    }

    // MARK: Test support

    /// "setup", "guide", "ai" or "closed".
    public var modeForTesting: String { isShown ? model.mode.rawValue : "closed" }
    /// The onboarding's step on show, or "closed".
    public var stepForTesting: String { isSetupShown ? model.step.rawValue : "closed" }
    public var levelForTesting: NSWindow.Level { window?.level ?? .normal }
    /// How far the footer's buttons sit above the window's bottom edge, as last laid out. Nil before they are.
    public var footerRoomForTesting: CGFloat? {
        guard isOpen, let height = window?.contentView?.bounds.height, model.footerFrame != .zero else { return nil }
        return height - model.footerFrame.maxY
    }
    public func pressForTesting(_ title: String) -> Bool { model.press(title) }
    /// As if another app had come to the front, by its bundle identifier.
    public func frontmostChangedForTesting(_ identifier: String?) {
        frontmost = identifier
        update()
    }
    /// Captures the window as it looks now, title bar included.
    public func captureForTesting(to url: URL) -> Bool {
        guard let view = window?.contentView?.superview, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
#endif
