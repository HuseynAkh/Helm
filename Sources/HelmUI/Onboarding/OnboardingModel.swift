#if os(macOS)
import AppKit
import Combine
import HelmCore

/// One thing the welcome window sets up, in the order the rows show.
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

/// The welcome window: a short checklist and the buttons that act on it. The window controller carries out closing.
///
/// Nothing changes until Set Up is pressed, and then only the rows that are checked. Not Now and the close button
/// change nothing. Every check is quiet: it reads the Mac, never asks it anything.
@MainActor public final class OnboardingModel: ObservableObject {
    public enum Mode: String, Sendable {
        /// The checklist: on the first launch, from Help › Set Up Helm…, and from Settings.
        case setup
        /// Only the Full Disk Access row, reached from a refusal, Help › Full Disk Access… or Settings.
        case guide
    }
    /// What the footer's main button does.
    public enum Action: Sendable { case setUp, openSettings, finish }

    @Published public private(set) var mode: Mode = .setup
    /// The rows the person wants set up. A row that's already done has no checkbox and isn't touched.
    @Published public private(set) var checked: Set<SetupRow> = Set(SetupRow.allCases)
    /// Set Up was pressed, or the guide opened System Settings: the window now shows how each row went.
    @Published public private(set) var started = false
    /// System Settings was opened from here, so a smaller button can open it again.
    @Published public private(set) var openedSettings = false
    /// The copy that ran before this one moved Helm into Applications a moment ago.
    @Published public private(set) var moved = false
    /// Full Disk Access was asked for (a card's Grant Access…, Help › Full Disk Access…) while the checklist was open.
    /// Its row then shows Helm's icon and its own Open System Settings button, which leaves the other rows alone.
    @Published public private(set) var accessHelpRequested = false
    @Published private var progress: [SetupRow: SetupRowState] = [:]

    public let permissions: PermissionCenter
    /// The default file viewer and Dock switches, as in Settings › General. Nil leaves that row out.
    public let fileViewer: FileViewerModel?
    public let mover: any AppMoving
    /// How long the check marks stay up once everything chosen is done, before the window closes by itself.
    public var finishDelay: TimeInterval = 1.5
    /// While VoiceOver is on, the window never closes by itself: it says everything is set up, and the person closes it.
    public var isVoiceOverRunning: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    /// What Set Up is doing, for tests to wait on.
    public private(set) var work: Task<Void, Never>?
    public var isFinishing: Bool { finishing != nil }
    /// What was last said to VoiceOver.
    public private(set) var lastAnnouncement: String?

    var close: () -> Void = {}
    /// Set Up or Not Now: the welcome has been seen. Closing it and quitting count too; the window controller sees to those.
    var seen: () -> Void = {}
    /// Something that decides whether the window watches for access, floats or resizes has changed.
    var changed: () -> Void = {}
    /// Saves the rows the copy in Applications carries on with, or clears them (nil). The app keeps them in its
    /// settings, so a copy that's opened by hand, without the flag, finds them too.
    var carry: ([SetupRow]?) -> Void = { _ in }
    /// Says something to VoiceOver.
    var announce: (String) -> Void = { _ in }
    /// The rows Set Up (or the guide's button) is seeing to.
    private var chosen: [SetupRow] = []
    private var finishing: Task<Void, Never>?
    /// Each start moves this on, and so does closing the window. A run of Set Up that's still waiting on macOS or on
    /// the copy then finds it's out of date and stops, instead of carrying on in a window that's gone or started over.
    private var generation = 0
    /// Asked for again just as it was about to close by itself, so it stays until the person closes it.
    private var staysOpen = false
    /// The copy already made in Applications, so trying again only has to reopen it.
    private var movedCopy: URL?
    /// How each row stood when last looked at, so only a change is announced.
    private var heard: [SetupRow: SetupRowState] = [:]
    private var forwarding: [AnyCancellable] = []

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

    /// The rows on show: only what applies to this copy of Helm.
    public var rows: [SetupRow] {
        if mode == .guide { return [.fullDiskAccess] }
        var shown: [SetupRow] = []
        if fileViewer?.canRegister == true { shown.append(.fileViewer) }
        if !isOutsideApp { shown.append(.fullDiskAccess) }
        if moved || mover.placement.needsMove { shown.append(.moveToApplications) }
        return shown
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
    /// at this copy, so from a disk image or macOS's temporary copy it goes only together with the move: the copy in
    /// Applications does it once it opens.
    public func unavailableReason(_ row: SetupRow) -> String? {
        guard mode == .setup, row == .fileViewer, !isDone(row), mover.placement.isTemporary,
              !checked.contains(.moveToApplications) else { return nil }
        return "Only with Move to Applications."
    }
    public func isAvailable(_ row: SetupRow) -> Bool { unavailableReason(row) == nil }

    /// Every row on show is done already, so there's nothing to set up.
    public var nothingToDo: Bool { rows.allSatisfy(isDone) }
    public func hasCheckbox(_ row: SetupRow) -> Bool { mode == .setup && !isDone(row) }
    /// A row that can't be done from here shows unticked, but keeps the person's choice for when it can.
    public func isChecked(_ row: SetupRow) -> Bool { checked.contains(row) && isAvailable(row) }
    /// Checkboxes can change until Set Up is pressed.
    public var canChoose: Bool { !started }
    public func setChecked(_ row: SetupRow, _ on: Bool) {
        guard canChoose, isAvailable(row) else { return }
        if on { checked.insert(row) } else { checked.remove(row) }
    }

    /// Helm's icon to drag into System Settings' list: in the guide, and in the checklist once System Settings is open
    /// or Full Disk Access was asked for.
    public var showsAccessHelp: Bool {
        guard !isDone(.fullDiskAccess) else { return false }
        return mode == .guide || state(of: .fullDiskAccess) == .waiting || (mode == .setup && accessHelpRequested)
    }
    /// The Full Disk Access row has its own Open System Settings button: in the checklist whenever it shows Helm's icon,
    /// and in the guide once the footer's button has been used.
    public var rowOpensSettings: Bool { showsAccessHelp && !isOutsideApp && (mode == .setup || openedSettings) }
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

    // MARK: The footer

    public var primaryAction: Action {
        switch mode {
        case .setup: return started || nothingToDo ? .finish : .setUp
        case .guide: return openedSettings || isDone(.fullDiskAccess) || isOutsideApp ? .finish : .openSettings
        }
    }
    public var primaryTitle: String {
        switch primaryAction {
        case .setUp: return "Set Up"
        case .openSettings: return "Open System Settings"
        case .finish: return "Done"
        }
    }
    /// Not Now, while there's still something to decide.
    public var secondaryTitle: String? { primaryAction == .finish ? nil : "Not Now" }

    public func primary() {
        switch primaryAction {
        case .setUp: setUp()
        case .openSettings: openFullDiskAccess()
        case .finish: close()
        }
    }
    /// Closes the window. Nothing changes.
    public func notNow() {
        seen()
        close()
    }

    /// Presses a button by its title, as a click would. Scripted runs use this; nobody is there to click.
    public func press(_ title: String) -> Bool {
        if title == primaryTitle { primary(); return true }
        if title == secondaryTitle { notNow(); return true }
        if title == "Open System Settings", rowOpensSettings { openFullDiskAccess(); return true }
        return false
    }

    // MARK: Doing it

    /// Starts afresh: every row checked, nothing done yet, and each row's state read again. A run of Set Up that's
    /// still going stops at its next step.
    public func begin(_ next: Mode) {
        stop()
        mode = next
        checked = Set(SetupRow.allCases)
        started = false; openedSettings = false; moved = false; accessHelpRequested = false; staysOpen = false
        progress = [:]; chosen = []; movedCopy = nil
        fileViewer?.refresh()
        // What's already done when it opens isn't news.
        heard = states()
        changed()
    }

    /// The guide becomes the checklist, as Help › Set Up Helm… asks while the guide is open. If System Settings is open
    /// and the guide waits for the switch, the checklist still does.
    public func switchToSetup() {
        guard mode == .guide else { return }
        let access = progress[.fullDiskAccess]
        let opened = openedSettings
        begin(.setup)
        progress[.fullDiskAccess] = access
        openedSettings = opened
        heard = states()
        changed()
    }

    /// Full Disk Access was asked for while the checklist is open, which has the same row: it now shows how to switch
    /// Helm on, with its own button for System Settings.
    public func requestAccessHelp() {
        guard mode == .setup, !isDone(.fullDiskAccess), !isOutsideApp else { return }
        accessHelpRequested = true
        changed()
    }

    /// The window was asked for again while it's open. If it was about to close by itself, it stays.
    public func askedForAgain() {
        guard let finishing else { return }
        finishing.cancel()
        self.finishing = nil
        staysOpen = true
    }

    /// Does every checked row that isn't done yet. When Helm needs moving, that goes first, and the copy in
    /// Applications does the rest after it reopens, so the file viewer and the Dock tile point at it.
    public func setUp() {
        guard mode == .setup, !started else { return }
        let picked = rows.filter { isChecked($0) && !isDone($0) }
        seen()
        // Whatever an earlier move saved for its copy has been overtaken by this.
        carry(nil)
        guard !picked.isEmpty else { close(); return }
        started = true
        chosen = picked
        changed()
        let run = generation
        work = Task { @MainActor [weak self] in await self?.run(picked, generation: run) }
    }

    private func run(_ picked: [SetupRow], generation run: Int) async {
        // Closed or started over before this run began: it does nothing.
        guard run == generation else { return }
        guard picked.contains(.moveToApplications) else { await apply(picked, generation: run); return }
        progress[.moveToApplications] = .working
        settle()
        let rest = picked.filter { $0 != .moveToApplications } + [.moveToApplications]
        let result: AppMoveResult
        if let copy = movedCopy, mover.hasCopy(at: copy) { result = .moved(copy) } else { result = await mover.moveToApplications() }
        if case .moved(let copy) = result {
            movedCopy = copy
            // Saved before anything quits, so the copy carries on even if it's opened by hand.
            carry(rest)
        }
        // The window closed or started over while Helm was being copied: nothing quits by itself.
        guard run == generation else { return }
        switch result {
        case .moved(let copy):
            // This Helm quits now, and the copy carries on. A quit that goes through never comes back here.
            if await mover.relaunch(from: copy, continuing: rest) { return }
            guard run == generation else { return }
            let folder = copy.deletingLastPathComponent()
            progress[.moveToApplications] = .failed("Couldn’t reopen from \(folder.path), so quit Helm and open it there.")
            started = false; chosen = []
        case .cancelled:
            // Nothing else is done either: the person can uncheck the move and set up the rest from here.
            progress[.moveToApplications] = nil
            started = false; chosen = []
        case .failed(let message):
            progress[.moveToApplications] = .failed(message)
            started = false; chosen = []
        }
        settle()
    }

    private func apply(_ picked: [SetupRow], generation run: Int) async {
        guard run == generation else { return }
        if picked.contains(.fileViewer), let viewer = fileViewer {
            progress[.fileViewer] = .working
            settle()
            // Helm becomes the file viewer straight away. Asking for folders too can wait on macOS, which may never
            // answer (macOS 26 refuses outright), so after a few seconds the Dock and Full Disk Access go ahead anyway.
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
            guard run == generation else { return }
            progress[.fileViewer] = (problem ?? viewer.problem).map { SetupRowState.failed($0) }
        }
        // System Settings opens only while this window is there to say what to do in it, and only once.
        guard run == generation else { return }
        if picked.contains(.fullDiskAccess) && state(of: .fullDiskAccess) != .waiting { openFullDiskAccess() }
        settle()
    }

    /// Opens System Settings at Full Disk Access. Only the person can switch Helm on there.
    public func openFullDiskAccess() {
        guard !isOutsideApp else { return }
        openedSettings = true
        progress[.fullDiskAccess] = permissions.open(.fullDiskAccess) ? .waiting
            : .failed("Choose Apple menu › System Settings › Privacy & Security › Full Disk Access.")
        if mode == .guide && !started { started = true; chosen = [.fullDiskAccess] }
        settle()
    }

    /// The copy that was just moved into Applications carries on with the rows the person chose before the move.
    public func continueSetup(_ carried: [SetupRow]) {
        begin(.setup)
        checked = Set(carried)
        // Still outside Applications, so the person starts again from the checklist.
        guard !mover.placement.needsMove else { return }
        moved = carried.contains(.moveToApplications)
        let picked = rows.filter { carried.contains($0) && $0 != .moveToApplications && !isDone($0) }
        chosen = picked + (moved ? [.moveToApplications] : [])
        guard !chosen.isEmpty else { return }
        started = true
        changed()
        let run = generation
        work = Task { @MainActor [weak self] in await self?.apply(picked, generation: run) }
    }

    /// Full Disk Access changed, so its row may be done now.
    func permissionsChanged() { settle() }
    /// The window closed: nothing is left to close by itself, and a Set Up that's still going stops at its next step.
    func closed() { stop() }

    private func stop() {
        generation += 1
        work?.cancel(); work = nil
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

    /// After anything changes: says what's new to VoiceOver, redraws, and closes by itself once everything is done.
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
        if let finished = finishIfDone() { news.append(finished) }
        if !news.isEmpty { say(news.joined(separator: " ")) }
        changed()
    }

    private func say(_ text: String) {
        lastAnnouncement = text
        announce(text)
    }

    /// Once everything chosen is done, the check marks stay up for a moment and the window closes by itself, unless
    /// VoiceOver is on: a window that vanishes while it's being read loses the person's place. Returns what to say.
    private func finishIfDone() -> String? {
        guard started, finishing == nil, !staysOpen, !chosen.isEmpty, chosen.allSatisfy({ state(of: $0) == .done }) else { return nil }
        if isVoiceOverRunning() {
            // Done is the default button, so the person needn't be told how to close it.
            staysOpen = true
            return Self.allSetUp
        }
        let delay = finishDelay
        finishing = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            self.finishing = nil
            self.close()
        }
        return Self.allSetUp
    }
    /// Said once everything chosen is done, whether or not the window then closes by itself.
    static let allSetUp = "Everything you chose is set up."
}
#endif
