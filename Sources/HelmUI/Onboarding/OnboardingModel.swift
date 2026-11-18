#if os(macOS)
import AppKit
import Combine
import HelmAgent
import HelmCore

/// One thing the onboarding sets up. Each belongs to a step: the move to the welcome step, Full Disk Access to its own,
/// and the file viewer to the Default File Viewer step.
public enum SetupRow: String, CaseIterable, Sendable {
    /// Helm as the default file viewer, and first in the Dock.
    case fileViewer = "viewer"
    case fullDiskAccess = "access"
    /// Only while Helm runs from a disk image, a translocated copy, or anywhere outside Applications.
    case moveToApplications = "move"

    public var title: String {
        switch self {
        case .fileViewer: return "Use Helm instead of Finder"
        case .fullDiskAccess: return "Full Disk Access"
        case .moveToApplications: return "Move to Applications"
        }
    }
    public var detail: String {
        switch self {
        case .fileViewer: return "“Show in Finder” opens Helm, which goes next to Finder in the Dock."
        case .fullDiskAccess: return "Lets Helm see the Trash and other apps’ folders."
        case .moveToApplications: return "Reopens Helm from there."
        }
    }
    /// The one line about folder access, under Full Disk Access while it's off. Nil for the other rows.
    public var folderNote: String? {
        self == .fullDiskAccess ? "Without it, macOS asks about Desktop, Documents and Downloads." : nil
    }
    /// What VoiceOver hears when the row turns done.
    var doneAnnouncement: String {
        switch self {
        case .fileViewer: return "Helm now opens instead of Finder."
        case .fullDiskAccess: return "Full Disk Access is on."
        case .moveToApplications: return "Helm is in Applications."
        }
    }

    /// The flag a copy that's just been moved into Applications opens with, to carry on where the person left off.
    public static let continueFlag = "--continue-setup"
    /// The rows as the flag carries them: "viewer,access,move", or "none".
    public static func flagValue(_ rows: [SetupRow]) -> String {
        rows.isEmpty ? "none" : rows.map(\.rawValue).joined(separator: ",")
    }
    /// Names it doesn't know are left out.
    public static func rows(fromFlag value: String) -> [SetupRow] {
        value.split(separator: ",").compactMap { SetupRow(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// Where a row stands. Whether it's done is read from the Mac (or the stand-ins) each time, never remembered.
public enum SetupRowState: Equatable, Sendable {
    case pending, working
    /// System Settings is open at Full Disk Access, and Helm waits for the switch.
    case waiting
    case done
    case failed(String)

    /// One word, for scripted runs.
    public var name: String {
        switch self {
        case .pending: return "pending"
        case .working: return "working"
        case .waiting: return "waiting"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}

/// The welcome window. As the onboarding it goes step by step: welcome, Full Disk Access, the default file viewer and
/// the Dock, AI mode, then done, with Back and Continue. As the guide it holds only the Full Disk Access row. The window
/// controller carries out closing.
///
/// Nothing changes until the person acts on a step: Continue on the welcome step moves Helm into Applications when it's
/// ticked, the Full Disk Access step opens System Settings only from its button, and Continue on the file viewer step
/// does that row when it's ticked. Every check is quiet: it reads the Mac, never asks it anything. Once Full Disk Access
/// is on, its step's button restarts Helm, as macOS's own Quit & Reopen does, since macOS applies it in full only from
/// the next launch. Either way the onboarding carries on where it was kept through `saveProgress`.
@MainActor public final class OnboardingModel: ObservableObject {
    public enum Mode: String, Sendable {
        /// The onboarding, step by step: on the first launch, from Help › Set Up Helm…, and from Settings.
        case setup
        /// Only the Full Disk Access row, reached from a refusal, Help › Full Disk Access… or Settings.
        case guide
        /// The AI mode screen on its own, drawn from `aiSetup`: from a window's spark while no model is ready, and once
        /// at launch for someone who set Helm up before AI mode existed.
        case ai
    }
    /// What the footer's main button does.
    public enum Action: Sendable { case next, openSettings, restart, finish }

    @Published public private(set) var mode: Mode = .setup
    /// The onboarding's steps on show, in order. Fixed when it starts, so the step indicator doesn't change under the person.
    @Published public private(set) var steps: [OnboardingStep] = []
    /// The step on show.
    @Published public private(set) var step: OnboardingStep = .welcome
    /// The rows the person wants done. A row that's already done has no checkbox and isn't touched.
    @Published public private(set) var checked: Set<SetupRow> = Set(SetupRow.allCases)
    /// The guide opened System Settings: the window now shows how its row went.
    @Published public private(set) var started = false
    /// System Settings was opened from here, so a smaller button can open it again.
    @Published public private(set) var openedSettings = false
    /// This copy was moved into Applications by the copy that ran before it.
    @Published public private(set) var moved = false
    /// Full Disk Access was asked for (a card's Grant Access…, Help › Full Disk Access…) while the onboarding was open.
    /// Its step then shows Helm's icon to drag.
    @Published public private(set) var accessHelpRequested = false
    @Published private var progress: [SetupRow: SetupRowState] = [:]
    /// What the AI mode screen, or the onboarding's AI step, shows and changes.
    @Published public private(set) var aiSetup: AISetupModel?
    /// Continue was pressed on the AI step. The step's screen hands over what was typed and not yet entered, as Done does.
    @Published public private(set) var aiContinueRequests = 0
    /// Continue on the AI step is waiting for the provider's answer.
    @Published public private(set) var aiChecking = false

    public let permissions: PermissionCenter
    /// The default file viewer and Dock switches, as in Settings › General. Nil leaves that step out.
    public let fileViewer: FileViewerModel?
    public let mover: any AppMoving
    /// Where the AI step's model comes from. Nil leaves the step out.
    public var aiSource: () -> AISetupModel? = { nil }
    /// How long a check mark stays up once a step's work is done, before the next step comes by itself.
    public var finishDelay: TimeInterval = 1.5
    /// While VoiceOver is on, the window never moves on or closes by itself: it says the row is done, and the person goes on.
    public var isVoiceOverRunning: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    /// What a step is doing, for tests to wait on.
    public private(set) var work: Task<Void, Never>?
    public var isFinishing: Bool { finishing != nil }
    /// What was last said to VoiceOver.
    public private(set) var lastAnnouncement: String?
    /// Where the window's footer buttons were last laid out, from its top left.
    var footerFrame: CGRect = .zero

    var close: () -> Void = {}
    /// The onboarding has been through: Get Started, or the window closed. The window controller sees to closing.
    var seen: () -> Void = {}
    /// Something that decides whether the window watches for access, floats or resizes has changed.
    var changed: () -> Void = {}
    /// Quits Helm and opens it again. The app sets it; the next step is kept first.
    var restart: () -> Void = {}
    /// Saves the rows the copy in Applications carries on with, or clears them (nil). The app keeps them in its
    /// settings, so a copy that's opened by hand, without the flag, finds them too.
    var carry: ([SetupRow]?) -> Void = { _ in }
    /// Keeps how far the onboarding got, so the next launch carries on there.
    var saveProgress: (OnboardingProgress) -> Void = { _ in }
    /// Continue on the AI step couldn't go on: the state on show says why.
    var refused: () -> Void = {}
    /// Says something to VoiceOver.
    var announce: (String) -> Void = { _ in }
    private var finishing: Task<Void, Never>?
    /// Each start moves this on, and so does closing the window. Work that's still waiting on macOS or on the copy then
    /// finds it's out of date and stops, instead of carrying on in a window that's gone or started over.
    private var generation = 0
    /// Asked for again just as it was about to move on or close by itself, so it stays until the person goes on.
    private var staysOpen = false
    /// The row whose work, once done, takes the onboarding to its next step by itself: the file viewer after Continue.
    /// Full Disk Access stays on its step, which then offers to restart Helm.
    private var advancesWhenDone: SetupRow?
    /// Continue or Not Now answered the AI step, so whatever the switch says stays when the onboarding ends.
    private(set) var aiAnswered = false
    /// AI mode was on when the AI step first showed, as for someone who set it up before: closing the onboarding leaves
    /// it as it was.
    private var aiOnBefore: Bool?
    /// The copy already made in Applications, so trying again only has to reopen it.
    private var movedCopy: URL?
    /// How each row stood when last looked at, so only a change is announced.
    private var heard: [SetupRow: SetupRowState] = [:]
    private var forwarding: [AnyCancellable] = []
    private var aiForwarding: AnyCancellable?

    /// Without a mover, a stand-in that never moves anything.
    public init(permissions: PermissionCenter, fileViewer: FileViewerModel?, mover: (any AppMoving)? = nil) {
        self.permissions = permissions; self.fileViewer = fileViewer; self.mover = mover ?? MemoryAppMover()
        // The rows read both live, so the window redraws when either changes.
        forwarding.append(permissions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        if let fileViewer {
            forwarding.append(fileViewer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        }
    }

    /// Helm runs outside an app bundle, from Terminal, so macOS applies Terminal's permissions.
    public var isOutsideApp: Bool { permissions.appURL == nil }

    // MARK: Steps

    /// Whether `step` has anything to show for this copy of Helm.
    public func applies(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome, .done: return true
        case .access: return !isOutsideApp
        case .viewer: return fileViewer?.canRegister == true
        case .ai: return aiSetup != nil || aiSource() != nil
        }
    }

    /// The steps an onboarding shows. A launch's leaves out what's done already; Help › Set Up Helm… shows them all, with
    /// how each stands. AI mode is always one, showing how it stands, so someone who set it up already just goes on.
    public func plannedSteps(skippingDone: Bool) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { step in
            guard applies(step) else { return false }
            switch step {
            case .access: return !(skippingDone && isDone(.fullDiskAccess))
            case .viewer: return !(skippingDone && isDone(.fileViewer))
            case .welcome, .ai, .done: return true
            }
        }
    }

    /// The step's place among the steps on show, from 0.
    public var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }
    /// The move to Applications shows on the welcome step while this copy needs it, or once it's been done.
    public var showsMove: Bool { moved || mover.placement.needsMove }

    /// The rows on the step on show: only what applies to this copy of Helm.
    public var rows: [SetupRow] {
        switch mode {
        case .ai: return []
        case .guide: return [.fullDiskAccess]
        case .setup:
            switch step {
            case .welcome: return showsMove ? [.moveToApplications] : []
            case .access: return [.fullDiskAccess]
            case .viewer: return [.fileViewer]
            case .ai, .done: return []
            }
        }
    }

    public func isDone(_ row: SetupRow) -> Bool {
        switch row {
        case .fileViewer: return fileViewer.map { $0.isHelmDefault && $0.isFirstInDock } ?? false
        case .fullDiskAccess: return permissions.fullDiskAccess == .granted
        case .moveToApplications: return moved
        }
    }

    public func state(of row: SetupRow) -> SetupRowState {
        let now = progress[row] ?? .pending
        switch now {
        case .working, .failed: return now
        default: return isDone(row) ? .done : now
        }
    }

    /// Why a row can't be done from where this copy runs, or nil when it can. Use Helm instead of Finder points the Dock
    /// at this copy, so from a disk image or macOS's temporary copy it goes only with the move: the copy in Applications
    /// does it once it opens.
    public func unavailableReason(_ row: SetupRow) -> String? {
        guard mode == .setup, row == .fileViewer, !isDone(row), mover.placement.isTemporary else { return nil }
        return "Only with Move to Applications."
    }
    public func isAvailable(_ row: SetupRow) -> Bool { unavailableReason(row) == nil }

    /// The line about folder access on the Full Disk Access step, only while it isn't done: once it's on, macOS asks
    /// about no folder.
    public func folderNote(_ row: SetupRow) -> String? {
        guard mode == .setup, !isDone(row) else { return nil }
        return row.folderNote
    }

    /// Nothing is left to set up: every step but the welcome and done is left out, and there's no move to make.
    public var nothingToDo: Bool { nothingLeft(besides: []) }
    /// Nothing is left but `others`, the welcome and done, and there's no move to make. A launch passes AI mode once it
    /// has been seen: its step shows in every onboarding, but on its own it's no reason to open one.
    public func nothingLeft(besides others: Set<OnboardingStep>) -> Bool {
        switch mode {
        case .setup:
            return steps.allSatisfy { $0 == .welcome || $0 == .done || others.contains($0) } && !(mover.placement.needsMove && !moved)
        case .guide, .ai: return rows.allSatisfy(isDone)
        }
    }
    /// The move and the file viewer have checkboxes until they're done. Full Disk Access has a button instead, since
    /// only the person can switch it on.
    public func hasCheckbox(_ row: SetupRow) -> Bool {
        mode == .setup && rows.contains(row) && row != .fullDiskAccess && !isDone(row)
    }
    /// A row that can't be done from here shows unticked, but keeps the person's choice for when it can.
    public func isChecked(_ row: SetupRow) -> Bool { checked.contains(row) && isAvailable(row) }
    /// Checkboxes can change until their step starts its work.
    public var canChoose: Bool { !isWorking }
    public func setChecked(_ row: SetupRow, _ on: Bool) {
        guard canChoose, isAvailable(row) else { return }
        if on { checked.insert(row) } else { checked.remove(row) }
    }
    /// A step's work is under way: the move, the file viewer, or the AI step's check. The buttons wait for it.
    public var isWorking: Bool { progress.values.contains(.working) || aiChecking }

    /// Full Disk Access was switched on while this Helm runs, and its step is on show. macOS applies it in full only
    /// from the next launch, so the step's button restarts Helm.
    public var offersRestart: Bool {
        mode == .setup && step == .access && !isOutsideApp && isDone(.fullDiskAccess) && permissions.switchedOnSinceLaunch
    }
    /// The Full Disk Access step's own Open System Settings button, while access is off.
    public var stepOpensSettings: Bool { mode == .setup && step == .access && !isDone(.fullDiskAccess) && !isOutsideApp }
    /// Helm's icon to drag into System Settings' list: in the guide, and on the Full Disk Access step once System Settings
    /// is open or access was asked for.
    public var showsAccessHelp: Bool {
        guard !isDone(.fullDiskAccess) else { return false }
        switch mode {
        case .guide: return true
        case .setup: return step == .access && (state(of: .fullDiskAccess) == .waiting || accessHelpRequested)
        case .ai: return false
        }
    }
    /// The guide's row has its own Open System Settings button once the footer's button has been used.
    public var rowOpensSettings: Bool { mode == .guide && showsAccessHelp && !isOutsideApp && openedSettings }
    /// Waiting for Full Disk Access, which is when the window watches for it and can float over System Settings.
    public var isWaitingForAccess: Bool { showsAccessHelp && !isOutsideApp }

    /// Full Disk Access in words, for VoiceOver and scripted runs.
    public var statusLine: String {
        switch state(of: .fullDiskAccess) {
        case .done: return "Full Disk Access is on"
        case .waiting: return "Waiting for Full Disk Access"
        default: return "Full Disk Access is off"
        }
    }

    /// The done step's list: each thing the onboarding offered, and whether it's on now.
    public var summary: [(title: String, on: Bool)] {
        var lines: [(title: String, on: Bool)] = []
        if steps.contains(.access) { lines.append((SetupRow.fullDiskAccess.title, isDone(.fullDiskAccess))) }
        if steps.contains(.viewer) { lines.append((SetupRow.fileViewer.title, isDone(.fileViewer))) }
        if steps.contains(.ai) { lines.append((AgentText.aiTitle, (aiSetup ?? aiSource()).map { $0.isOn && $0.isConnected } ?? false)) }
        return lines
    }

    // MARK: The footer

    public var primaryAction: Action {
        switch mode {
        case .setup: return step == .done ? .finish : offersRestart ? .restart : .next
        case .guide: return openedSettings || isDone(.fullDiskAccess) || isOutsideApp ? .finish : .openSettings
        case .ai: return .finish
        }
    }
    public var primaryTitle: String {
        switch (mode, primaryAction) {
        case (.setup, .finish): return Self.getStarted
        case (_, .next): return Self.continueTitle
        case (_, .openSettings): return Self.openSettingsTitle
        case (_, .restart): return Self.restartTitle
        case (_, .finish): return AgentText.done
        }
    }
    /// Not Now: on the AI step, and in the guide while there's still something to decide.
    public var secondaryTitle: String? {
        switch mode {
        case .setup: return step == .ai ? Self.notNowTitle : nil
        case .guide: return primaryAction == .finish ? nil : Self.notNowTitle
        case .ai: return nil
        }
    }
    /// Back, on every step of the onboarding but the first.
    public var backTitle: String? { mode == .setup && stepIndex > 0 ? Self.backTitle : nil }
    /// The line under the title: the step's own.
    public var headerLine: String? { mode == .setup ? step.subtitle : nil }

    public static let continueTitle = "Continue"
    public static let getStarted = "Get Started"
    public static let backTitle = "Back"
    public static let notNowTitle = "Not Now"
    public static let openSettingsTitle = "Open System Settings"
    public static let restartTitle = "Restart Helm"
    /// On the Full Disk Access step: what happens once Helm is switched on, so macOS's question isn't a surprise.
    public static let reopenNote = "macOS will ask to quit and reopen Helm, and setup continues after."

    public func primary() {
        switch primaryAction {
        case .next: next()
        case .openSettings: openFullDiskAccess()
        case .restart: restartHelm()
        case .finish: if mode == .setup { finish() } else { close() }
        }
    }

    /// The footer's Continue, as clicked. On the AI step the screen first hands over what was typed and not yet entered.
    public func continuePressed() {
        if mode == .setup && step == .ai && aiSetup?.donePressed != nil && !isWorking { aiContinueRequests += 1 } else { primary() }
    }

    /// On the AI step, leaves AI mode off and goes on. In the guide, closes the window. Nothing else changes.
    public func notNow() {
        switch mode {
        case .setup:
            guard step == .ai, !isWorking else { return }
            aiSetup?.closedWithoutDone()
            aiAnswered = true
            advance()
        case .guide, .ai:
            seen()
            close()
        }
    }

    /// Back to the step before. Nothing that step did is undone.
    public func back() {
        guard mode == .setup, !isWorking, stepIndex > 0 else { return }
        go(to: steps[stepIndex - 1])
    }

    /// Presses a button by its title, as a click would. Scripted runs use this; nobody is there to click.
    public func press(_ title: String) -> Bool {
        switch mode {
        case .ai:
            return aiSetup?.pressed(title) ?? false
        case .guide:
            if title == primaryTitle { primary(); return true }
            if title == secondaryTitle { notNow(); return true }
            if title == Self.openSettingsTitle, rowOpensSettings { openFullDiskAccess(); return true }
            return false
        case .setup:
            guard !isWorking else { return false }
            if title == backTitle { back(); return true }
            if title == primaryTitle { primary(); return true }
            if title == secondaryTitle { notNow(); return true }
            if title == Self.openSettingsTitle, stepOpensSettings { openFullDiskAccess(); return true }
            if step == .ai { return aiSetup?.pressed(title) ?? false }
            return false
        }
    }

    // MARK: Starting

    /// Starts afresh in `next`. For the onboarding that's every step that applies, from the welcome; Help › Set Up
    /// Helm… asks for this. A run of a step's work that's still going stops at its next step.
    public func begin(_ next: Mode) {
        if next == .setup { startSetup(steps: plannedSteps(skippingDone: false)); return }
        reset(next)
        changed()
    }

    /// The onboarding with `steps`, from `first`. A launch passes the steps still to do.
    public func startSetup(steps planned: [OnboardingStep], at first: OnboardingStep = .welcome) {
        reset(.setup)
        steps = planned.isEmpty ? [.welcome, .done] : planned
        enter(steps.contains(first) ? first : steps[0])
    }

    /// Carries on from where an onboarding stopped, as after macOS's Quit & Reopen. A step that no longer applies is left
    /// out. Full Disk Access that's on now takes it past its step. A copy left behind after a move starts again from the
    /// welcome, where the move is; `carried` are the rows the copy that moved Helm left for this one.
    public func resume(_ saved: OnboardingProgress, carried: [SetupRow] = []) {
        reset(.setup)
        steps = saved.steps.filter(applies)
        let wasMoved = saved.moved || carried.contains(.moveToApplications)
        moved = wasMoved && !mover.placement.needsMove
        var at = steps.contains(saved.step) ? saved.step : (next(after: saved.step) ?? .done)
        if wasMoved && mover.placement.needsMove { at = .welcome }
        if at == .welcome && moved { at = next(after: .welcome) ?? .done }
        if saved.askedForAccess && !isOutsideApp && !isDone(.fullDiskAccess) {
            openedSettings = true
            progress[.fullDiskAccess] = .waiting
        }
        if at == .access && isDone(.fullDiskAccess) { at = next(after: .access) ?? .done }
        heard = states()
        enter(at)
    }

    /// The copy that was just moved into Applications carries on, after the welcome step where the move was. With no
    /// progress kept, it starts from the steps that are left.
    public func continueSetup(_ carried: [SetupRow], resuming saved: OnboardingProgress? = nil) {
        if let saved { resume(saved, carried: carried); return }
        startSetup(steps: plannedSteps(skippingDone: true))
        // Still outside Applications, so the person starts again from the welcome step, where the move is.
        guard carried.contains(.moveToApplications), !mover.placement.needsMove else { return }
        moved = true
        go(to: next(after: .welcome) ?? .done)
    }

    /// Starts the AI mode screen on its own, drawn from `model`. The window follows the model's changes, so it fits
    /// what the screen shows.
    public func beginAI(_ model: AISetupModel) {
        reset(.ai)
        follow(model)
        changed()
    }

    /// The AI mode screen was asked for while the onboarding is open: it goes to its AI step, adding it before done.
    public func showAIStep(_ model: AISetupModel? = nil) {
        guard mode == .setup, !isWorking else { return }
        if aiSetup == nil, let model { follow(model) }
        if !steps.contains(.ai) {
            guard aiSetup != nil || aiSource() != nil else { return }
            steps.insert(.ai, at: steps.firstIndex(of: .done) ?? steps.count)
        }
        if step != .ai { go(to: .ai) }
    }

    /// The guide becomes the onboarding at its Full Disk Access step, as Help › Set Up Helm… asks while the guide is
    /// open. If System Settings is open and the guide waits for the switch, the step still does.
    public func switchToSetup() {
        guard mode == .guide else { return }
        let access = progress[.fullDiskAccess]
        let opened = openedSettings
        startSetup(steps: plannedSteps(skippingDone: false), at: .access)
        progress[.fullDiskAccess] = access
        openedSettings = opened
        heard = states()
        keep()
        changed()
    }

    /// Full Disk Access was asked for while the onboarding is open: it goes to that step, which shows how to switch Helm
    /// on.
    public func requestAccessHelp() {
        guard mode == .setup, !isDone(.fullDiskAccess), !isOutsideApp, !isWorking, steps.contains(.access) else { return }
        accessHelpRequested = true
        if step != .access { go(to: .access) } else { changed() }
    }

    /// The window was asked for again while it's open. If it was about to move on or close by itself, it stays.
    public func askedForAgain() {
        guard let finishing else { return }
        finishing.cancel()
        self.finishing = nil
        staysOpen = true
    }

    // MARK: Going from step to step

    /// Continue: does the step's work when it has some, then moves on. On the welcome step that's the move, when it's
    /// ticked; on the file viewer step, that row when it's ticked; on the AI step, what Done does on the AI mode screen.
    public func next() {
        guard mode == .setup, !isWorking else { return }
        cancelFinishing()
        switch step {
        case .welcome:
            if rows.contains(.moveToApplications) && isChecked(.moveToApplications) && !isDone(.moveToApplications) { startMove(); return }
            advance()
        case .viewer:
            if isChecked(.fileViewer) && !isDone(.fileViewer) { applyFileViewer(); return }
            advance()
        case .ai:
            continueFromAI(pendingKey: nil)
        case .access:
            advance()
        case .done:
            finish()
        }
    }

    private func next(after step: OnboardingStep) -> OnboardingStep? {
        guard let index = OnboardingStep.allCases.firstIndex(of: step) else { return nil }
        return OnboardingStep.allCases.dropFirst(index + 1).first(where: steps.contains)
    }

    private func advance() {
        guard let next = next(after: step) else { finish(); return }
        go(to: next)
    }

    private func go(to next: OnboardingStep) {
        cancelFinishing()
        staysOpen = false
        advancesWhenDone = nil
        enter(next)
        say("\(next.title). Step \(stepIndex + 1) of \(steps.count).")
    }

    /// Shows `next`, keeps it as the place to carry on from, and readies what it needs.
    private func enter(_ next: OnboardingStep) {
        if step == .ai && next != .ai { aiSetup?.donePressed = nil }
        step = next
        if next == .ai, let model = aiSetup ?? aiSource() {
            if aiSetup !== model { follow(model) }
            aiAnswered = false
            if aiOnBefore == nil { aiOnBefore = model.isOn }
            // Done on the screen, in a script, comes here, as the footer's Continue does.
            model.donePressed = { [weak self] key in self?.continueFromAI(pendingKey: key) }
        }
        if next == .viewer { fileViewer?.refresh() }
        heard = states()
        keep()
        changed()
    }

    /// The onboarding is through: Get Started.
    private func finish() {
        guard mode == .setup else { close(); return }
        seen()
        close()
    }

    private func keep() {
        guard mode == .setup, !steps.isEmpty else { return }
        saveProgress(OnboardingProgress(step: step, steps: steps, askedForAccess: openedSettings, moved: moved))
    }

    private func follow(_ model: AISetupModel) {
        aiSetup = model
        aiForwarding = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func reset(_ next: Mode) {
        stop()
        if aiSetup?.donePressed != nil, mode == .setup, step == .ai { aiSetup?.donePressed = nil }
        aiSetup = nil; aiForwarding = nil
        mode = next
        steps = []; step = .welcome
        checked = Set(SetupRow.allCases)
        started = false; openedSettings = false; moved = false; accessHelpRequested = false; staysOpen = false
        aiChecking = false; aiAnswered = false; aiOnBefore = nil; advancesWhenDone = nil
        progress = [:]; movedCopy = nil
        fileViewer?.refresh()
        // What's already done when it opens isn't news.
        heard = states()
    }

    // MARK: Each step's work

    /// The move goes first, on the welcome step. The copy in Applications carries on from the next step once it opens,
    /// so the file viewer and the Dock tile point at it.
    private func startMove() {
        progress[.moveToApplications] = .working
        settle()
        let run = generation
        work = Task { @MainActor [weak self] in await self?.runMove(generation: run) }
    }

    private func runMove(generation run: Int) async {
        guard run == generation else { return }
        let result: AppMoveResult
        if let copy = movedCopy, mover.hasCopy(at: copy) { result = .moved(copy) } else { result = await mover.moveToApplications() }
        if case .moved(let copy) = result {
            movedCopy = copy
            // Saved before anything quits, so the copy carries on even if it's opened by hand.
            carry([.moveToApplications])
            let after = next(after: .welcome) ?? .done
            saveProgress(OnboardingProgress(step: after, steps: steps, askedForAccess: openedSettings, moved: true))
        }
        // The window closed or started over while Helm was being copied: nothing quits by itself.
        guard run == generation else { return }
        switch result {
        case .moved(let copy):
            // This Helm quits now, and the copy carries on. A quit that goes through never comes back here.
            if await mover.relaunch(from: copy, continuing: [.moveToApplications]) { return }
            guard run == generation else { return }
            let folder = copy.deletingLastPathComponent()
            progress[.moveToApplications] = .failed("Couldn’t reopen from \(folder.path), so quit Helm and open it there.")
            keep()
        case .cancelled:
            // Nothing else changes: the person can untick the move and go on from here.
            progress[.moveToApplications] = nil
        case .failed(let message):
            progress[.moveToApplications] = .failed(message)
        }
        settle()
    }

    /// Helm becomes the file viewer straight away. Asking for folders too can wait on macOS, which may never answer
    /// (macOS 26 refuses outright), so after a few seconds the Dock goes ahead anyway.
    private func applyFileViewer() {
        guard let viewer = fileViewer, isAvailable(.fileViewer) else { advance(); return }
        progress[.fileViewer] = .working
        advancesWhenDone = .fileViewer
        settle()
        let run = generation
        work = Task { @MainActor [weak self] in
            let problem: String? = await withCheckedContinuation { continuation in
                let once = ResumeOnce()
                viewer.setHelmDefault(true) { message in if once.claim() { continuation.resume(returning: message) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if once.claim() { continuation.resume(returning: nil) } }
            }
            // The file viewer has switched already, so the Dock follows even if the window has gone meanwhile, rather
            // than leaving the row half done.
            if problem == nil {
                if viewer.isWorking { viewer.refresh() }
                viewer.setFirstInDock(true)
            }
            guard let self, run == self.generation else { return }
            self.progress[.fileViewer] = (problem ?? viewer.problem).map { SetupRowState.failed($0) }
            self.settle()
        }
    }

    /// Continue on the AI step: what Done does on the AI mode screen. A typed key is entered and checked; the step goes
    /// on when the switch is off or the provider is connected, and otherwise stays, with the state saying why.
    func continueFromAI(pendingKey: String?) {
        guard mode == .setup, step == .ai, let ai = aiSetup, !isWorking else { return }
        aiChecking = true
        let run = generation
        work = Task { @MainActor [weak self] in
            let leaves = await ai.done(pendingKey: pendingKey)
            guard let self, run == self.generation, self.step == .ai else { return }
            self.aiChecking = false
            if leaves {
                self.aiAnswered = true
                self.advance()
            } else {
                self.refused()
            }
        }
    }

    /// Opens System Settings at Full Disk Access. Only the person can switch Helm on there.
    public func openFullDiskAccess() {
        guard !isOutsideApp else { return }
        openedSettings = true
        progress[.fullDiskAccess] = permissions.open(.fullDiskAccess) ? .waiting
            : .failed("Choose Apple menu › System Settings › Privacy & Security › Full Disk Access.")
        if mode == .guide && !started { started = true }
        if mode == .setup && step == .access { keep() }
        settle()
    }

    /// Restart Helm: the next step is kept first, so the launch that follows carries on there, as after macOS's own Quit
    /// & Reopen.
    private func restartHelm() {
        guard offersRestart, !isWorking else { return }
        cancelFinishing()
        saveProgress(OnboardingProgress(step: next(after: .access) ?? .done, steps: steps, moved: moved))
        restart()
    }

    /// Full Disk Access changed, so its row may be done now.
    func permissionsChanged() { settle() }
    /// The window closed. Work still going stops at its next step. An AI step that was shown but never answered with
    /// Continue or Not Now leaves AI mode off, as closing the AI mode screen does, unless it was on before the step
    /// showed: only Continue turns it on and leaves it on.
    func closed() {
        stop()
        if mode == .setup, aiOnBefore == false, !aiAnswered, let ai = aiSetup, ai.isOn { ai.closedWithoutDone() }
        if mode == .setup, step == .ai { aiSetup?.donePressed = nil }
    }
    /// The process is ending with the window open, as macOS's Quit & Reopen ends it: work stops, and nothing else
    /// changes, so the next launch carries on from the step that was kept.
    func ended() {
        stop()
        if mode == .setup, step == .ai { aiSetup?.donePressed = nil }
    }

    private func stop() {
        generation += 1
        work?.cancel(); work = nil
        cancelFinishing()
    }
    private func cancelFinishing() {
        finishing?.cancel(); finishing = nil
    }

    /// Reads every row again, as when the window opens or Helm comes back to the front.
    public func refresh() {
        fileViewer?.refresh()
        objectWillChange.send()
        settle()
    }

    // MARK: Telling the person

    private func states() -> [SetupRow: SetupRowState] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0, state(of: $0)) })
    }

    /// After anything changes: says what's new to VoiceOver, redraws, and moves on by itself once a step's work is done.
    private func settle() {
        var news: [String] = []
        let now = states()
        for row in rows where now[row] != heard[row] {
            switch now[row] {
            case .done?: news.append(row.doneAnnouncement)
            case .failed(let message)?: news.append("\(row.title) didn’t work. \(message)")
            default: break
            }
        }
        heard = now
        if let finished = moveOnIfDone() { news.append(finished) }
        if !news.isEmpty { say(news.joined(separator: " ")) }
        changed()
    }

    private func say(_ text: String) {
        lastAnnouncement = text
        announce(text)
    }

    /// Once a step's work is done, the check mark stays up for a moment and the next step comes by itself, or the guide
    /// closes, unless VoiceOver is on: a window that changes while it's being read loses the person's place. Returns what
    /// to say.
    private func moveOnIfDone() -> String? {
        guard finishing == nil, !staysOpen else { return nil }
        let ready: Bool
        switch mode {
        case .guide: ready = started && state(of: .fullDiskAccess) == .done
        case .setup: ready = advancesWhenDone.map { rows.contains($0) && state(of: $0) == .done } ?? false
        case .ai: ready = false
        }
        guard ready else { return nil }
        advancesWhenDone = nil
        if isVoiceOverRunning() {
            // Continue (or Done) is the default button, so the person needn't be told how to go on.
            staysOpen = true
            return mode == .guide ? Self.allSetUp : nil
        }
        let delay = finishDelay
        let leaving = mode
        finishing = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            self.finishing = nil
            if leaving == .guide { self.close() } else { self.advance() }
        }
        return mode == .guide ? Self.allSetUp : nil
    }
    /// Said once the guide's Full Disk Access is on, whether or not the window then closes by itself.
    static let allSetUp = "Everything you chose is set up."
}
#endif
