#if os(macOS)
import AppKit
import Combine
import HelmAgent
import HelmCore
import SwiftUI

/// The welcome window, shown once on first launch and again from Help or Settings. As the guide it holds only the
/// Full Disk Access row. While that row waits, Full Disk Access is checked every moment, and while System Settings is in
/// front the window stays above it, so Helm's icon can be dragged across. In AI mode it shows the AI mode screen, dark,
/// whose Done is the only way to leave AI mode on.
@MainActor public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    public let model: OnboardingModel
    /// Called once the checklist (not the guide on its own) has been seen: Set Up, Not Now, closing it, or Helm
    /// quitting with it open (`quitting()`). At most once each time it opens.
    public var onSeen: (() -> Void)?
    /// Saves (or, with nil, clears) the rows the copy in Applications carries on with. The app keeps them in its settings.
    public var onCarry: (([SetupRow]?) -> Void)?
    /// Called after the window closes, with the mode it was in. The app shows the AI mode screen once the first
    /// launch's checklist has gone.
    public var onClosed: ((OnboardingModel.Mode) -> Void)?
    private let host: NSHostingController<OnboardingView>
    private var counted = false
    private var isWatching = false
    /// Open, whether on screen or hidden along with Helm (Command-H). A hidden window isn't visible, but it's still
    /// open: quitting then still counts it as seen, and asking for it again keeps what it's doing.
    private var isOpen = false
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
        super.init(window: window)
        window.delegate = self
        model.close = { [weak self] in self?.close() }
        model.seen = { [weak self] in self?.markSeen() }
        model.changed = { [weak self] in self?.update() }
        model.carry = { [weak self] rows in self?.onCarry?(rows) }
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
    /// it keeps what it's doing: the guide turns into the checklist still waiting for Full Disk Access, and the checklist
    /// asked for the guide shows its Full Disk Access row's icon and button. Either way it no longer closes by itself.
    public func show(_ mode: OnboardingModel.Mode, activate: Bool) {
        // The AI mode screen gives way to the checklist or the guide. Leaving it so isn't Done.
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

    /// The AI mode screen, drawn from `ai`. Done closes it when the switch is off or the provider is connected, and then
    /// calls `onDone` with whether it ended connected. Closing it any other way turns AI mode off. Asked for while the
    /// checklist is open, it takes the checklist's place, which then counts as seen.
    public func showAIMode(_ ai: AISetupModel, activate: Bool, onDone: @escaping (Bool) -> Void) {
        if isOpen && model.mode == .ai && model.aiSetup === ai {
            aiDone = onDone
            present(activate: activate)
            return
        }
        if isOpen && model.mode == .ai { leaveAIMode() }
        if isOpen { markSeen() }
        aiDone = onDone
        ai.donePressed = { [weak self] key in self?.pressDone(pendingKey: key) }
        start { $0.beginAI(ai) }
        present(activate: activate)
    }

    /// Done: commits a typed key, then closes if the model says the screen may.
    private func pressDone(pendingKey: String?) {
        guard aiDoneWork == nil, let ai = model.aiSetup else { return }
        aiDoneWork = Task { @MainActor [weak self] in
            let leaves = await ai.done(pendingKey: pendingKey)
            guard let self else { return }
            self.aiDoneWork = nil
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

    /// The copy that was just moved into Applications reopens the checklist and carries on with what was chosen.
    public func continueSetup(_ rows: [SetupRow], activate: Bool) {
        start { $0.continueSetup(rows) }
        present(activate: activate)
    }

    private func start(_ body: (OnboardingModel) -> Void) {
        counted = false
        body(model)
    }

    private func present(activate: Bool) {
        isOpen = true
        interactive = activate
        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        switch model.mode {
        case .setup: window?.title = "Welcome to Helm"
        case .guide: window?.title = "Full Disk Access"
        case .ai: window?.title = AgentText.aiTitle
        }
        // The AI mode screen is always dark; the checklist follows the Mac.
        window?.appearance = model.mode == .ai ? NSAppearance(named: .darkAqua) : nil
        // Live status: the file viewer and the Dock are read again, in case they changed while the window was away.
        model.refresh()
        fit()
        if activate {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.orderFrontRegardless()
        }
        update()
        // So is Full Disk Access, quietly.
        Task { @MainActor [weak self] in await self?.model.permissions.refresh() }
    }

    /// Open, even while Helm is hidden.
    public var isShown: Bool { isOpen }
    /// The checklist is open, rather than the guide on its own.
    public var isSetupShown: Bool { isOpen && model.mode == .setup }

    /// Helm is quitting. The checklist counts as seen if it's open, so it doesn't open again on the next launch.
    public func quitting() {
        if isSetupShown { markSeen() }
        if isOpen && model.mode == .ai { leaveAIMode() }
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
        let height = ceil(host.sizeThatFits(in: NSSize(width: OnboardingView.width, height: 4000)).height)
        guard height > 0, abs(content.frame.height - height) > 0.5 || abs(content.frame.width - OnboardingView.width) > 0.5 else { return }
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: OnboardingView.width, height: height))
        var origin = NSPoint(x: window.frame.minX, y: top - window.frame.height)
        // Growing downwards mustn't take the buttons off the bottom of the screen.
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame { origin.y = max(origin.y, screen.minY) }
        window.setFrameOrigin(origin)
    }

    static let systemSettings = "com.apple.systempreferences"
    /// The window floats only while System Settings is in front and Full Disk Access is still off, so Helm's icon can
    /// be dragged into its list. Otherwise it's an ordinary window, which other apps cover as usual.
    static func level(waitingForAccess: Bool, interactive: Bool, hasAccess: Bool, frontmost: String?) -> NSWindow.Level {
        waitingForAccess && interactive && !hasAccess && frontmost == systemSettings ? .floating : .normal
    }

    public func windowWillClose(_ notification: Notification) {
        let mode = model.mode
        if mode == .ai && !closingByDone { leaveAIMode() }
        isOpen = false
        if isWatching { isWatching = false; model.permissions.watch(false) }
        model.closed()
        window?.level = .normal
        markSeen()
        if let onClosed { DispatchQueue.main.async { MainActor.assumeIsolated { onClosed(mode) } } }
    }

    // MARK: Test support

    /// "setup", "guide", "ai" or "closed".
    public var modeForTesting: String { isShown ? model.mode.rawValue : "closed" }
    public var levelForTesting: NSWindow.Level { window?.level ?? .normal }
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
