#if os(macOS)
import AppKit
import XCTest
import HelmAgent
import HelmCore
import HelmFileSystem
import HelmOperations
import HelmPersistence
import HelmTestKit
@testable import HelmApp
@testable import HelmUI

/// The AI panel in a real window on a throwaway home on disk, with a stand-in conversation: opening and shutting
/// it, the room it makes, who has the keys, and a plan applied through the window's real file commands and undone
/// in one step.
@MainActor final class AgentPanelWindowTests: XCTestCase {
    private var temp: TempDirectory!
    private var home: URL!
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var sorted: URL { documents.appendingPathComponent("Sorted", isDirectory: true) }
    private var other: URL { documents.appendingPathComponent("Other", isDirectory: true) }
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []
    private var messages: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        temp = try TempDirectory()
        home = temp.url.appendingPathComponent("home", isDirectory: true)
        for folder in [documents, sorted, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for name in ["a.txt", "b.txt", "c.txt"] { try Data(name.utf8).write(to: documents.appendingPathComponent(name)) }
        // A name already taken where b.txt is going.
        try Data("older b".utf8).write(to: sorted.appendingPathComponent("b.txt"))
    }
    override func tearDownWithError() throws {
        for controller in controllers { controller.window?.close() }
        controllers = []; keep = []; messages = []
        HeaderMotion.isDisabledForTesting = false
        try temp?.remove()
        try super.tearDownWithError()
    }

    // MARK: Building

    /// A window on Documents, and the box that makes the conversation its panel talks to, when the panel first opens.
    /// AI mode is on unless asked otherwise.
    private func window(on: Bool = true, wrap: ((any FileSystem) -> any FileSystem)? = nil)
        async throws -> (BrowserWindowController, PanelConversationBox, PanelWindowHost) {
        let directories = AppDirectories(home: home, applicationSupport: temp.url.appendingPathComponent("support", isDirectory: true))
        let env = try await AppEnvironment.live(directories: directories, settingsStorage: IsolatedSettings(),
                                                legacyReader: NoLegacyDefaults(),
                                                trash: fixtureTrash(in: temp.url.appendingPathComponent("trash", isDirectory: true)))
        let fileSystem = wrap?(env.fileSystem) ?? env.fileSystem
        let box = PanelConversationBox()
        let secrets = MemorySecretStore()
        let disk = MemoryAgentDisk(home: home.path)
        let parts = AgentRuntimeParts(secrets: secrets, disk: disk, home: home.path, supportFolder: directories.applicationSupport.path,
                                      clock: env.clock, buildStamp: "", scripted: ScriptedModelClient(),
                                      makeSession: { _ in box.make() })
        let runtime = AgentRuntime(parts: parts)
        let agent = AgentServices(runtime: runtime, config: AIConfigStore(), secrets: secrets, disk: disk,
                                  storage: MemoryStorageFactsReader(home: home), connector: MemoryServerConnector())
        if on { runtime.setOn(true) }
        let operations = OperationCoordinator(fileSystem: fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: home) { false }
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: fileSystem,
            operations: operations, home: home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.agent-panel.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith, agent: agent)
        dependencies.settings.set(.bool(false), for: .askOnConflict)
        let host = PanelWindowHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "agent-panel", seeds: [], activeIndex: 0)
        keep += [host, operations, volumes, env.settings]
        controllers.append(controller)
        controller.messageObserver = { [weak self] in self?.messages.append($0) }
        controller.navigate(to: .directory(documents))
        let arrived = await until { controller.activeTab?.location == .directory(self.documents) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "Documents never opened")
        return (controller, box, host)
    }

    private func until(_ timeout: TimeInterval = 30, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// Opens the panel and waits for it to know the tab's folder.
    private func open(_ controller: BrowserWindowController) async throws -> AgentPanelModel {
        controller.clickSparkForTesting()
        XCTAssertTrue(controller.isAgentPanelOpen)
        let model = try XCTUnwrap(controller.agentPanelModelForTesting)
        let ready = await until(10) { model.chipsForTesting == ["Documents:thisMac"] && !model.isWaitingForTesting }
        XCTAssertTrue(ready, "the panel never knew the folder")
        return model
    }

    private func settle(_ controller: BrowserWindowController, _ model: AgentPanelModel) async {
        _ = await until { !model.isWaitingForTesting && !controller.isRunningOperations && controller.activeTab?.isLoading == false }
        await controller.refreshHistoryForTesting()
    }

    private func item(_ url: URL, _ fileSystem: any FileSystem, kind: FileEntryKind = .regular) async throws -> AgentPlanItem {
        let identity = try await fileSystem.mutationPrecondition(at: url).identity
        return AgentPlanItem(handle: url.lastPathComponent, rootAlias: "r1", path: url.path, name: url.lastPathComponent,
                             kind: kind, identity: identity, isDataless: false)
    }

    /// a.txt into a new Images folder, b.txt into Sorted, where its name is taken, and a copy of c.txt into Sorted.
    private func organizePlan(_ controller: BrowserWindowController) async throws -> AgentChangePlan {
        let fileSystem = controller.dependencies.fileSystem
        let root = try await item(documents, fileSystem, kind: .directory)
        let sortedItem = try await item(sorted, fileSystem, kind: .directory)
        let steps: [AgentPlanStep] = [
            .newFolder(key: "n1", parent: .existing(root), name: ValidFileName("Images")!),
            .move(try await item(documents.appendingPathComponent("a.txt"), fileSystem), to: .new(key: "n1")),
            .move(try await item(documents.appendingPathComponent("b.txt"), fileSystem), to: .existing(sortedItem)),
            .copy(try await item(documents.appendingPathComponent("c.txt"), fileSystem), to: .existing(sortedItem))
        ]
        let groups = [AgentPlanGroup(id: 0, kind: .moves(toLabel: "Images", isNew: true), steps: [0, 1]),
                      AgentPlanGroup(id: 1, kind: .moves(toLabel: "Sorted", isNew: false), steps: [2]),
                      AgentPlanGroup(id: 2, kind: .copies(toLabel: "Sorted", isNew: false), steps: [3])]
        return AgentChangePlan(title: .organize(rootLabel: "Documents"), steps: steps, groups: groups, notices: [],
                               keepsBoth: [2], leftOut: [:])
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = [], repeats: Bool = false,
                     in controller: BrowserWindowController) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: text,
                                       charactersIgnoringModifiers: text, isARepeat: repeats, keyCode: code))
    }

    // MARK: Opening and shutting

    func testThePanelOpensAndShutsByTheButtonAndTheCommand() async throws {
        let (controller, _, _) = try await window()
        let window = try XCTUnwrap(controller.window)
        let width = window.frame.width
        _ = try await open(controller)
        XCTAssertEqual(controller.agentPanelHost.frame.width, AgentPanelHost.width)
        XCTAssertEqual(controller.title(of: .aiPanel).0, AgentText.menuHidePanel)
        XCTAssertGreaterThanOrEqual(controller.contentContainer.frame.width, AgentPanelHost.minimumFilesWidth)
        XCTAssertEqual(controller.contentContainer.frame.maxX, controller.agentPanelHost.frame.minX, accuracy: 0.5,
                       "the files end where the panel starts")
        XCTAssertEqual(window.frame.width, width, "a wide window keeps its width")
        XCTAssertTrue(controller.isSidebarVisibleForTesting, "and its sidebar")

        controller.clickSparkForTesting()
        XCTAssertFalse(controller.isAgentPanelOpen)
        XCTAssertEqual(controller.agentPanelHost.frame.width, 0)
        XCTAssertEqual(controller.title(of: .aiPanel).0, AgentText.menuShowPanel)

        controller.perform(.aiPanel)
        XCTAssertTrue(controller.isAgentPanelOpen)
        XCTAssertEqual(controller.agentPanelHost.frame.width, AgentPanelHost.width)
        controller.perform(.aiPanel)
        XCTAssertFalse(controller.isAgentPanelOpen)
        XCTAssertEqual(controller.agentPanelHost.frame.width, 0)
        XCTAssertNotNil(controller.agentPanelModelForTesting, "the thread stays for the next time it opens")
    }

    func testANarrowWindowFirstHidesTheSidebarThenWidens() async throws {
        let (controller, _, _) = try await window()
        let window = try XCTUnwrap(controller.window)
        // Room for the files once the sidebar goes: the window keeps its width.
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        controller.split.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.isSidebarVisibleForTesting)
        _ = try await open(controller)
        XCTAssertFalse(controller.isSidebarVisibleForTesting, "the sidebar made room")
        XCTAssertEqual(window.frame.width, 900, accuracy: 0.5, "the window kept its width")
        XCTAssertGreaterThanOrEqual(controller.contentContainer.frame.width, AgentPanelHost.minimumFilesWidth - 0.5)
        controller.clickSparkForTesting()

        // Too narrow even without the sidebar: the window grows by what is missing.
        window.setFrame(NSRect(x: 0, y: 0, width: 620, height: 600), display: false)
        controller.split.view.layoutSubtreeIfNeeded()
        controller.clickSparkForTesting()
        XCTAssertTrue(controller.isAgentPanelOpen)
        XCTAssertGreaterThanOrEqual(window.frame.width, AgentPanelHost.width + AgentPanelHost.minimumFilesWidth - 0.5)
        XCTAssertGreaterThanOrEqual(controller.contentContainer.frame.width, AgentPanelHost.minimumFilesWidth - 0.5)
        XCTAssertEqual(controller.agentPanelHost.frame.width, AgentPanelHost.width)
        controller.clickSparkForTesting()
        XCTAssertEqual(controller.split.splitViewItems.last?.minimumThickness, 420, "the files' own minimum is back once shut")
    }

    // MARK: Resizing

    func testThePanelsLimits() {
        XCTAssertEqual(AgentPanelHost.widest(inWindowWidth: 1400), 560, "560 points at most")
        XCTAssertEqual(AgentPanelHost.widest(inWindowWidth: 1000), 450, "or 45% of the window, whichever is less")
        XCTAssertEqual(AgentPanelHost.widest(inWindowWidth: 620), 340, "never under the width it opens at")
        XCTAssertEqual(AgentPanelHost.clamped(200, windowWidth: 1400), 300)
        XCTAssertEqual(AgentPanelHost.clamped(900, windowWidth: 1400), 560)
        XCTAssertEqual(AgentPanelHost.clamped(500, windowWidth: 1000), 450)
        XCTAssertEqual(AgentPanelHost.clamped(410.4, windowWidth: 1400), 410)
    }

    func testTheEdgeResizesThePanelWithinItsLimitsAndADoubleClickPutsBack340() async throws {
        let (controller, _, _) = try await window()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 700), display: false)
        controller.split.view.layoutSubtreeIfNeeded()
        let settings = controller.dependencies.settings
        _ = try await open(controller)
        let host = controller.agentPanelHost
        XCTAssertEqual(host.frame.width, 340)
        // The handle sits on the panel's leading edge, over the divider, with the resize cursor.
        XCTAssertEqual(host.edgeFrameForTesting.minX, 0)
        XCTAssertEqual(host.edgeFrameForTesting.height, host.frame.height, accuracy: 0.5)
        if #available(macOS 15.0, *) { XCTAssertTrue(host.edgeCursorForTesting === NSCursor.columnResize) }

        host.dragEdgeForTesting(by: 100)
        XCTAssertEqual(host.frame.width, 440)
        XCTAssertEqual(settings.snapshot.double(.agentPanelWidth), 440, "kept once the drag ends")
        XCTAssertEqual(controller.contentContainer.frame.maxX, host.frame.minX, accuracy: 0.5, "the files end where it starts")
        XCTAssertEqual(controller.split.splitViewItems.last?.minimumThickness, 440 + AgentPanelHost.minimumFilesWidth)
        host.dragEdgeForTesting(by: 400)
        XCTAssertEqual(host.frame.width, 560, "560 at most")
        host.dragEdgeForTesting(by: -500)
        XCTAssertEqual(host.frame.width, 300, "300 at least")
        XCTAssertEqual(settings.snapshot.double(.agentPanelWidth), 300)
        XCTAssertGreaterThanOrEqual(controller.contentContainer.frame.width, AgentPanelHost.minimumFilesWidth)
        host.doubleClickEdgeForTesting()
        XCTAssertEqual(host.frame.width, 340)
        XCTAssertEqual(settings.snapshot.double(.agentPanelWidth), 340)
        XCTAssertEqual(window.frame.width, 1400, accuracy: 0.5, "a drag never changes the window")
        XCTAssertTrue(controller.isSidebarVisibleForTesting, "or hides the sidebar")
    }

    func testADragNeverTakesTheFilesUnderTheirMinimum() async throws {
        let (controller, _, _) = try await window()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 700), display: false)
        controller.split.view.layoutSubtreeIfNeeded()
        _ = try await open(controller)
        let host = controller.agentPanelHost
        host.dragEdgeForTesting(by: 300)
        XCTAssertLessThanOrEqual(host.frame.width, 450, "45% of the window")
        XCTAssertGreaterThanOrEqual(controller.contentContainer.frame.width, AgentPanelHost.minimumFilesWidth - 0.5,
                                    "the files keep their room")
        XCTAssertEqual(window.frame.width, 1000, accuracy: 0.5)
    }

    /// The edge as a person drags it: presses, moves and releases sent to the window, so each press goes wherever
    /// the window's own hit-testing sends it. Presses on the line itself and a few points into the panel, beside the
    /// folders row, the thread and the composer, all resize it.
    func testPressesOnTheEdgeSentToTheWindowResizeThePanel() async throws {
        let (controller, _, _) = try await window()
        let window = try XCTUnwrap(controller.window)
        // A window takes presses only once it is ordered in: this one is, but invisible, behind every other window
        // and out of the way of the pointer, as a smoke run keeps its windows.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderBack(nil)
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 700), display: false)
        controller.split.view.layoutSubtreeIfNeeded()
        let settings = controller.dependencies.settings
        let model = try await open(controller)
        model.type("hello")
        model.send()
        _ = await until(10) { !model.isWaitingForTesting }
        let host = controller.agentPanelHost
        XCTAssertEqual(host.frame.width, 340)
        var width: CGFloat = 340
        // On the line, then a few points in: beside the folders row at the top, down the thread, and beside the
        // composer at the bottom.
        for (x, height) in [(0.5, 0.5), (3, 0.97), (5, 0.8), (2, 0.5), (4, 0.25), (3, 0.04)] as [(CGFloat, CGFloat)] {
            try drag(host, from: NSPoint(x: x, y: host.bounds.height * height), by: 30)
            width += 30
            XCTAssertEqual(host.frame.width, width, "a drag from \(x) points in, \(Int(height * 100))% up")
            XCTAssertEqual(settings.snapshot.double(.agentPanelWidth), Double(width), "kept once released")
        }
        XCTAssertEqual(controller.contentContainer.frame.maxX, host.frame.minX, accuracy: 0.5, "the files end where it starts")
        try drag(host, from: NSPoint(x: 3, y: host.bounds.midY), by: 300)
        XCTAssertEqual(host.frame.width, 560, "560 at most")
        try drag(host, from: NSPoint(x: 3, y: host.bounds.midY), by: -600)
        XCTAssertEqual(host.frame.width, 300, "300 at least")
        XCTAssertEqual(settings.snapshot.double(.agentPanelWidth), 300)
        // A double click: two presses, the second with a click count of 2.
        try drag(host, from: NSPoint(x: 3, y: host.bounds.midY), by: 0)
        try drag(host, from: NSPoint(x: 3, y: host.bounds.midY), by: 0, clicks: 2)
        XCTAssertEqual(host.frame.width, 340, "a double click puts back 340")
        XCTAssertEqual(settings.snapshot.double(.agentPanelWidth), 340)
        XCTAssertEqual(window.frame.width, 1400, accuracy: 0.5, "a drag never changes the window")
        XCTAssertTrue(controller.isSidebarVisibleForTesting, "or hides the sidebar")
    }

    /// A press at `point`, in the panel's coordinates, then moves `distance` points towards the leading side in four
    /// steps and a release, each sent to the window as the window server sends it. The moves and the release are
    /// queued first, so a view that follows the mouse in a loop of its own takes them from the queue; what is left
    /// is sent on, as the run loop would.
    private func drag(_ host: AgentPanelHost, from point: NSPoint, by distance: CGFloat, clicks: Int = 1) throws {
        let window = try XCTUnwrap(host.window)
        let start = host.convert(point, to: nil)
        let stamp = ProcessInfo.processInfo.systemUptime
        func mouse(_ type: NSEvent.EventType, x: CGFloat, _ index: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [],
                                             timestamp: stamp + Double(index) * 0.01, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: index, clickCount: clicks,
                                             pressure: type == .leftMouseUp ? 0 : 1))
        }
        let down = try mouse(.leftMouseDown, x: start.x, 0)
        var rest = try (1...4).map { try mouse(.leftMouseDragged, x: start.x - distance * CGFloat($0) / 4, $0) }
        rest.append(try mouse(.leftMouseUp, x: start.x - distance, 5))
        for event in rest { NSApp.postEvent(event, atStart: false) }
        window.sendEvent(down)
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(next)
        }
    }

    func testTheWidthIsKeptForTheNextOpeningAndAsMuchOfItAsAWindowAllows() async throws {
        let (controller, _, _) = try await window()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 700), display: false)
        controller.split.view.layoutSubtreeIfNeeded()
        let settings = controller.dependencies.settings
        _ = try await open(controller)
        controller.agentPanelHost.dragEdgeForTesting(by: 140)
        XCTAssertEqual(controller.agentPanelHost.frame.width, 480)
        controller.clickSparkForTesting()
        XCTAssertEqual(controller.agentPanelHost.frame.width, 0)
        controller.clickSparkForTesting()
        XCTAssertEqual(controller.agentPanelHost.frame.width, 480, "it opens as wide as it was left")
        controller.clickSparkForTesting()

        // A narrower window opens it at 45% of the window, and keeps the width chosen for a wider one.
        window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 700), display: false)
        controller.split.view.layoutSubtreeIfNeeded()
        controller.clickSparkForTesting()
        XCTAssertEqual(controller.agentPanelHost.frame.width, 450)
        XCTAssertGreaterThanOrEqual(controller.contentContainer.frame.width, AgentPanelHost.minimumFilesWidth - 0.5,
                                    "the sidebar made room for the width chosen")
        XCTAssertEqual(settings.snapshot.double(.agentPanelWidth), 480)
        // Made narrower while open, the window takes the panel down with it.
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        controller.split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.agentPanelHost.frame.width, 405)
        controller.clickSparkForTesting()

        // A width read back from Settings, as at the next launch, opens the panel the same way.
        settings.set(.double(380), for: .agentPanelWidth)
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 700), display: false)
        controller.split.view.layoutSubtreeIfNeeded()
        controller.clickSparkForTesting()
        XCTAssertEqual(controller.agentPanelHost.frame.width, 380)
    }

    // MARK: The location bar

    func testAPressAnywhereOutsideTheLocationBarClosesItAndGoesNowhere() async throws {
        let (controller, _, _) = try await window()
        _ = try await open(controller)
        XCTAssertTrue(controller.isSidebarVisibleForTesting)
        XCTAssertFalse(controller.watchesLocationPressesForTesting, "nothing is watched while the bar isn't typed in")
        for part in ["panel", "files", "sidebar", "header"] {
            controller.perform(.location)
            controller.store.send(.tab(controller.activeTabID, .addressBar(.textChanged(home.path))))
            XCTAssertEqual(controller.activeTab?.addressBar.isEditing, true)
            XCTAssertTrue(controller.watchesLocationPressesForTesting)
            // A press inside the bar is the bar's own.
            XCTAssertTrue(controller.pressForTesting(in: "path"))
            XCTAssertEqual(controller.activeTab?.addressBar.isEditing, true, part)
            XCTAssertTrue(controller.pressForTesting(in: part), part)
            XCTAssertEqual(controller.activeTab?.addressBar.isEditing, false, "a press on the \(part) closes the bar")
            XCTAssertFalse(controller.watchesLocationPressesForTesting, part)
            XCTAssertEqual(controller.activeTab?.location, .directory(documents), "and goes nowhere")
            XCTAssertEqual(controller.focusOwnerForTesting, "files", "the keys go back as Escape gives them")
        }
        XCTAssertTrue(controller.isAgentPanelOpen)
    }

    func testShuttingThePanelGivesBackTheRoomItTook() async throws {
        let (controller, _, _) = try await window()
        let window = try XCTUnwrap(controller.window)
        // At 900 opening hid the sidebar; shutting brings it back, with the header's buttons where they were.
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        controller.split.view.layoutSubtreeIfNeeded()
        _ = try await open(controller)
        XCTAssertFalse(controller.isSidebarVisibleForTesting)
        XCTAssertEqual(controller.headerLeadingForTesting, 84)
        controller.clickSparkForTesting()
        XCTAssertTrue(controller.isSidebarVisibleForTesting, "the sidebar the panel hid is back")
        XCTAssertEqual(controller.headerLeadingForTesting, 8)
        XCTAssertEqual(window.frame.width, 900, accuracy: 0.5)

        // At 700 it also widened the window; shutting gives the width back.
        window.setFrame(NSRect(x: 0, y: 0, width: 700, height: 600), display: false)
        controller.split.view.layoutSubtreeIfNeeded()
        controller.clickSparkForTesting()
        XCTAssertEqual(window.frame.width, AgentPanelHost.width + AgentPanelHost.minimumFilesWidth, accuracy: 0.5)
        controller.clickSparkForTesting()
        XCTAssertEqual(window.frame.width, 700, accuracy: 0.5, "the width it added is gone")
        XCTAssertTrue(controller.isSidebarVisibleForTesting)

        // What the person changes while it is open is theirs: a resize keeps its width and the sidebar stays hidden.
        controller.clickSparkForTesting()
        var frame = window.frame
        frame.size.width = 1000
        window.setFrame(frame, display: false)
        controller.clickSparkForTesting()
        XCTAssertEqual(window.frame.width, 1000, accuracy: 0.5)
        XCTAssertFalse(controller.isSidebarVisibleForTesting, "the person resized, so nothing comes back on its own")
        // And a sidebar the person shows and hides again stays as they left it.
        controller.toggleSidebar()
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        controller.split.view.layoutSubtreeIfNeeded()
        controller.clickSparkForTesting()
        XCTAssertFalse(controller.isSidebarVisibleForTesting)
        controller.toggleSidebar()
        controller.toggleSidebar()
        controller.clickSparkForTesting()
        XCTAssertFalse(controller.isSidebarVisibleForTesting, "the person hid it themselves")
    }

    /// Opened at any width, the panel makes room for the whole list beside it: no column is past the list's edge, and
    /// Size, Modified and Kind show their words whole, Name giving way first. Shut, the columns are as they were.
    /// Narrowed further by hand, Name goes down to its least before the others cut their words.
    func testTheListFitsBesideThePanelAtEveryWidth() async throws {
        let (controller, _, _) = try await window()
        let window = try XCTUnwrap(controller.window)
        controller.perform(.list)
        let listed = await until { controller.listRowNamesForTesting.contains("a.txt") }
        XCTAssertTrue(listed)
        func resize(_ width: CGFloat) {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: false)
            controller.split.view.layoutSubtreeIfNeeded()
        }
        func fits(_ label: String) -> [ListColumnFit] {
            let fit = controller.listColumnFitForTesting()
            for column in fit { XCTAssertTrue(column.isOnShow, "\(column.column) is past the edge at \(label): \(fit)") }
            return fit
        }
        for (width, sidebar) in [(1240, true), (1100, true), (1040, true), (951, true), (900, true), (900, false), (760, false), (700, true)]
            as [(CGFloat, Bool)] {
            let label = "\(Int(width))\(sidebar ? " with the sidebar" : "")"
            resize(width)
            if controller.isSidebarVisibleForTesting != sidebar { controller.toggleSidebar() }
            resize(width)
            let shut = fits("\(label), shut")
            XCTAssertEqual(shut.map(\.column), ["name", "size", "dateModified", "kind"])
            _ = try await open(controller)
            let open = fits("\(label), open")
            let name = open.first?.width ?? 0
            XCTAssertGreaterThanOrEqual(name, FileListController.leastNameWidth - 0.5, "\(label): \(open)")
            XCTAssertTrue(open.allSatisfy(\.wordsWhole), "\(label): \(open)")
            controller.clickSparkForTesting()
            XCTAssertFalse(controller.isAgentPanelOpen)
            controller.split.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(controller.listColumnFitForTesting(), shut, "shut again at \(label), the columns are as they were")
        }
        resize(1240)
        if !controller.isSidebarVisibleForTesting { controller.toggleSidebar() }
        _ = try await open(controller)
        // Narrowed by hand with the panel open: Name gives way down to its least, and only then do the others cut words.
        for width: CGFloat in [1100, 1000, 951, 900, 820, 760] {
            resize(width)
            let fit = controller.listColumnFitForTesting()
            let name = fit.first?.width ?? 0
            XCTAssertGreaterThanOrEqual(name, FileListController.leastNameWidth - 0.5, "\(Int(width)): \(fit)")
            if name > FileListController.leastNameWidth + 0.5 {
                XCTAssertTrue(fit.allSatisfy { $0.wordsWhole && $0.isOnShow }, "Name had room to give at \(Int(width)): \(fit)")
            }
        }
        controller.clickSparkForTesting()
    }

    /// Opened in a 900-point window, the panel makes room for Kind's words whole, Name giving way first, at the usual
    /// text size and at a larger one, where Kind's words are wider than the width Kind starts at.
    func testAt900WithThePanelOpenKindIsCutOnlyAfterName() async throws {
        let (controller, _, _) = try await window()
        let window = try XCTUnwrap(controller.window)
        controller.perform(.list)
        let listed = await until { controller.listRowNamesForTesting.contains("a.txt") }
        XCTAssertTrue(listed)
        defer { controller.resetText() }
        for steps in [0, 4] {
            if steps > 0 {
                controller.stepText(by: steps)
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            var frame = window.frame
            frame.size.width = 900
            window.setFrame(frame, display: false)
            controller.split.view.layoutSubtreeIfNeeded()
            _ = try await open(controller)
            controller.split.view.layoutSubtreeIfNeeded()
            let fit = controller.listColumnFitForTesting()
            let name = fit.first { $0.column == "name" }?.width ?? 0
            let kind = try XCTUnwrap(fit.first { $0.column == "kind" }, "\(fit)")
            XCTAssertTrue(fit.allSatisfy(\.isOnShow), "text \(controller.textPercent)%: \(fit)")
            XCTAssertGreaterThanOrEqual(name, FileListController.leastNameWidth - 0.5, "text \(controller.textPercent)%: \(fit)")
            XCTAssertTrue(kind.wordsWhole, "Kind is cut, text \(controller.textPercent)%: \(fit)")
            controller.clickSparkForTesting()
            XCTAssertFalse(controller.isAgentPanelOpen)
            controller.split.view.layoutSubtreeIfNeeded()
        }
    }

    func testTheMainMenuIsWholeWithThePanelOpenAtEveryWidth() async throws {
        let (controller, _, _) = try await window()
        let window = try XCTUnwrap(controller.window)
        _ = try await open(controller)
        for width: CGFloat in [760, 900, 1040, 1240, 1600, 760] {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: false)
            controller.split.view.layoutSubtreeIfNeeded()
            let measure = controller.headerMenuMeasureForTesting
            XCTAssertEqual(measure.size, NSSize(width: 34, height: 32), "\(width)")
            XCTAssertEqual(measure.trailingGap, 8, accuracy: 0.5, "\(width)")
            let ink = try XCTUnwrap(measure.ink)
            XCTAssertTrue(measure.bounds.insetBy(dx: 1, dy: 1).contains(ink), "\(ink) at \(width)")
        }
    }

    func testFindWithAITurnsTheFieldsSparkOverFromTheMenu() async throws {
        let (off, _, _) = try await window(on: false)
        XCTAssertFalse(off.title(of: .findWithAI).1, "off while no model is ready")
        let (controller, _, _) = try await window()
        XCTAssertTrue(controller.title(of: .findWithAI).1)
        controller.perform(.findWithAI)
        XCTAssertTrue(controller.isSearchingForTesting, "the search opens")
        XCTAssertTrue(controller.header.searchField.isAIOn)
        XCTAssertEqual(controller.menuItemStateForTesting(.findWithAI), .on)
        controller.perform(.findWithAI)
        XCTAssertFalse(controller.header.searchField.isAIOn)
        XCTAssertEqual(controller.menuItemStateForTesting(.findWithAI), .off)
    }

    func testWithNoModelReadyThePressAsksForTheAIModeScreen() async throws {
        let (controller, _, host) = try await window(on: false)
        controller.clickSparkForTesting()
        controller.perform(.aiPanel)
        XCTAssertEqual(host.aiScreenRequests, 2)
        XCTAssertFalse(controller.isAgentPanelOpen)
        XCTAssertEqual(controller.agentPanelHost.frame.width, 0)
        controller.openAgentPanel()
        XCTAssertFalse(controller.isAgentPanelOpen, "nothing to open while no model is ready")

        controller.dependencies.agent.runtime.setOn(true)
        controller.openAgentPanel()
        XCTAssertTrue(controller.isAgentPanelOpen, "Done on the AI mode screen opens it")
        XCTAssertEqual(host.aiScreenRequests, 2)

        // AI mode off again: the panel shuts and its conversation goes.
        controller.dependencies.agent.runtime.setOn(false)
        XCTAssertFalse(controller.isAgentPanelOpen)
        XCTAssertNil(controller.agentPanelModelForTesting)
    }

    // MARK: Keys

    func testTheComposerHoldsTheKeysAndTheFilesGetNone() async throws {
        let (controller, box, _) = try await window()
        let notes = try XCTUnwrap(controller.activeTab?.snapshot.sortedEntries.first { $0.name == "a.txt" })
        controller.store.send(.tab(controller.activeTabID, .setSelection([notes.id], source: .user)))
        let model = try await open(controller)
        XCTAssertEqual(controller.focusOwnerForTesting, "assistant", "the caret is in the composer")
        let fileCommands: [CommandID] = [.rename, .quickLook, .trash, .open]
        XCTAssertEqual(fileCommands.map { controller.title(of: $0).1 }, [false, false, false, false], "no file command can act")

        // Each key goes the way AppKit sends it: to the window's views as a key equivalent, then to the menu bar,
        // whose Rename is plain Return, Quick Look is Space and Move to Trash is Command-Delete, then to the composer.
        // While the composer has the keys those rows are off, so what matters is that none of them acted.
        let menu = fileMenu(for: controller)
        let text = controller.agentPanelHost.composerTextViewForTesting
        for event in [try key(36, "\r", in: controller), try key(49, " ", in: controller), try key(51, "\u{8}", .command, in: controller)] {
            XCTAssertFalse(controller.window?.performKeyEquivalent(with: event) ?? true, "a view took key \(event.keyCode)")
            _ = menu.performKeyEquivalent(with: event)
            menu.update()
            XCTAssertEqual(menu.items.map(\.isEnabled), [false, false, false], "a file row was on for key \(event.keyCode)")
            text.keyDown(with: event)
        }
        await settle(controller, model)
        XCTAssertNil(controller.activeTab?.inlineRenameID, "Return renamed nothing")
        XCTAssertEqual(controller.activeTab?.selection, [notes.id], "the selection is untouched")
        XCTAssertEqual(model.composerTextForTesting, " ", "Space was typed, not a preview")
        XCTAssertTrue(FileManager.default.fileExists(atPath: documents.appendingPathComponent("a.txt").path), "nothing went to the Trash")
        XCTAssertEqual(box.made?.sent.count, 0)
        XCTAssertEqual(controller.focusOwnerForTesting, "assistant", "sending keeps the caret")

        // Escape gives the keys back.
        text.keyDown(with: try key(53, "\u{1b}", in: controller))
        XCTAssertEqual(controller.focusOwnerForTesting, "files")
        XCTAssertEqual(controller.title(of: .rename).1, true, "the file commands are back")
        // The same Return through the menu bar now renames, so the pass above could have caught a leak.
        XCTAssertTrue(menu.performKeyEquivalent(with: try key(36, "\r", in: controller)), "the menu bar's Rename takes Return again")
        let renaming = await until(10) { controller.activeTab?.inlineRenameID != nil }
        XCTAssertTrue(renaming, "Return renames once the files have the keys")
    }

    /// The File menu's rows for Return, Space and Command-Delete, as the menu bar builds them, aimed at this window.
    private func fileMenu(for controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.autoenablesItems = true
        for (title, command, key, flags) in [("Rename", CommandID.rename, "\r", NSEvent.ModifierFlags()),
                                             ("Quick Look", .quickLook, " ", []),
                                             ("Move to Trash", .trash, "\u{8}", .command)] {
            let item = NSMenuItem(title: title, action: #selector(BrowserWindowController.helmCommand(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            item.representedObject = command.rawValue
            item.target = controller
            menu.addItem(item)
        }
        keep.append(menu)
        return menu
    }

    func testPlainReturnNeverAppliesAndCommandReturnDoes() async throws {
        let (controller, model, _) = try await windowWithPlan()
        let text = controller.agentPanelHost.composerTextViewForTesting
        controller.agentPanelHost.focusComposer()
        text.keyDown(with: try key(36, "\r", in: controller))
        text.keyDown(with: try key(76, "\r", in: controller))
        await settle(controller, model)
        XCTAssertEqual(model.phaseForTesting, "plan", "plain Return pressed nothing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: documents.appendingPathComponent("a.txt").path))

        // The repeats of a held Command-Return are taken and press nothing.
        XCTAssertTrue(text.performKeyEquivalent(with: try key(36, "\r", .command, repeats: true, in: controller)))
        text.keyDown(with: try key(36, "\r", .command, repeats: true, in: controller))
        await settle(controller, model)
        XCTAssertEqual(model.phaseForTesting, "plan", "a repeated key pressed nothing")

        XCTAssertTrue(text.performKeyEquivalent(with: try key(36, "\r", .command, in: controller)))
        await settle(controller, model)
        XCTAssertEqual(model.phaseForTesting, "result")
        XCTAssertTrue(FileManager.default.fileExists(atPath: documents.appendingPathComponent("Images/a.txt").path))
    }

    // MARK: Apply and Undo

    func testApplyRunsRealCommandsKeepsBothAndOneUndoPutsEverythingBack() async throws {
        let (controller, model, plan) = try await windowWithPlan()
        model.press(AgentText.apply)
        await settle(controller, model)
        XCTAssertEqual(model.phaseForTesting, "result")
        XCTAssertEqual(names(in: documents.appendingPathComponent("Images")), ["a.txt"])
        XCTAssertEqual(names(in: documents), ["Images", "Other", "Sorted", "c.txt"])
        let inSorted = names(in: sorted)
        XCTAssertEqual(inSorted.count, 3, "both b.txt files and the copy: \(inSorted)")
        XCTAssertTrue(inSorted.contains("b.txt") && inSorted.contains("c.txt"))
        XCTAssertEqual(try String(contentsOfFile: sorted.appendingPathComponent("b.txt").path, encoding: .utf8), "older b",
                       "the older file was kept, never replaced")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.resultOrganized(items: 2, folders: 2)))
        // The Edit menu as the files see it: while the composer has the keys, Undo is the composer's own.
        controller.focusFilesForTesting()
        XCTAssertEqual(controller.title(of: .undo).0, "Undo " + plan.title.text, "the Edit menu names the plan once")
        XCTAssertEqual(messages, [], "Apply shows no message of its own")

        model.press(AgentText.undo)
        await settle(controller, model)
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.undoDone))
        XCTAssertEqual(names(in: documents), ["Other", "Sorted", "a.txt", "b.txt", "c.txt"], "everything is back in one step")
        XCTAssertEqual(names(in: sorted), ["b.txt"])
        controller.focusFilesForTesting()
        XCTAssertNotEqual(controller.title(of: .undo).0, "Undo " + plan.title.text)
        XCTAssertFalse(controller.title(of: .redo).1, "an undone plan can't be redone")
    }

    func testASourceReplacedBetweenTwoCommandsIsSkippedAndTheRestStillRun() async throws {
        let swapper = PanelSwapper()
        let (controller, model, _) = try await windowWithPlan(wrap: { PanelSwappingFileSystem(inner: $0, swapper: swapper) },
                                                               swapAfterMoving: true, swapper: swapper)
        model.press(AgentText.apply)
        await settle(controller, model)
        XCTAssertTrue(swapper.swapped, "b.txt was replaced while a.txt moved")
        XCTAssertEqual(names(in: documents.appendingPathComponent("Images")), ["a.txt"], "the first command ran")
        XCTAssertEqual(try String(contentsOfFile: documents.appendingPathComponent("b.txt").path, encoding: .utf8), "a new b",
                       "the file that took b.txt's place stayed where it is")
        XCTAssertEqual(names(in: sorted), ["b.txt", "c.txt"], "the copy after it still ran")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.resultPartial(done: 3, total: 4, skipped: 1)),
                      model.threadTextForTesting)
    }

    func testStopBeforeTheFirstCommandRunsNothingAndSaysSo() async throws {
        let (controller, model, _) = try await windowWithPlan()
        model.press(AgentText.apply)
        model.press(AgentText.stop)
        await settle(controller, model)
        XCTAssertEqual(model.phaseForTesting, "result")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.resultStopped(done: 0, total: 4)), model.threadTextForTesting)
        XCTAssertEqual(names(in: documents), ["Other", "Sorted", "a.txt", "b.txt", "c.txt"], "nothing ran")
    }

    func testApplyPressedTwiceRunsOnce() async throws {
        let (controller, model, plan) = try await windowWithPlan()
        XCTAssertEqual(model.phase, .plan)
        // Two approvals of the same card, as two presses would make.
        let approval = AgentPlanCard(plan: plan, roots: []).approval()
        async let first = controller.applyAgentPlan(approval)
        async let second = controller.applyAgentPlan(approval)
        let reports = await [first, second]
        XCTAssertEqual(reports.compactMap { $0 }.count, 1, "the conversation lets a plan go once")
        // And through the card: a press while it applies does nothing.
        await settle(controller, model)
        XCTAssertEqual(names(in: sorted).filter { $0.hasPrefix("c") }.count, 1, "c.txt was copied once")
        model.press(AgentText.apply)
        await settle(controller, model)
        XCTAssertEqual(names(in: sorted).filter { $0.hasPrefix("c") }.count, 1)
    }

    func testAStaleTicketRunsNothingAndShowsTheChangedLine() async throws {
        let (controller, model, plan) = try await windowWithPlan()
        let conversation = try XCTUnwrap(model.sessionForTesting as? StandInConversation)
        let changed = AgentChangePlan(title: plan.title, steps: plan.steps, groups: plan.groups, notices: [], leftOut: [:])
        conversation.nextTicket = .changed(changed)
        model.press(AgentText.apply)
        await settle(controller, model)
        XCTAssertEqual(names(in: documents), ["Other", "Sorted", "a.txt", "b.txt", "c.txt"], "nothing ran")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.planChanged))
        XCTAssertEqual(model.phaseForTesting, "plan")
    }

    // MARK: Folders and servers

    func testATabFolderTheSessionRefusesShowsTheRefusedLine() async throws {
        let (controller, box, _) = try await window()
        box.folderAnswers = [documents.path: .refused(.system)]
        controller.clickSparkForTesting()
        let model = try XCTUnwrap(controller.agentPanelModelForTesting)
        let refused = await until(10) { model.phaseForTesting == "noFolder" && !model.isWaitingForTesting }
        XCTAssertTrue(refused)
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.folderRefused))
        XCTAssertEqual(model.suggestionsForTesting, [])
    }

    func testTheConnectorRecordsATypedServerOnlyAfterConnect() async throws {
        let (controller, _, _) = try await window()
        let connector = try XCTUnwrap(controller.dependencies.agent.connector as? MemoryServerConnector)
        let model = try await open(controller)
        model.type("smb://nas.local/share")
        model.send()
        await settle(controller, model)
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.serverConfirm("nas.local")))
        XCTAssertEqual(connector.opened, [], "nothing reached macOS before Connect")
        model.press(AgentText.connect)
        XCTAssertEqual(connector.opened.map(\.absoluteString), ["smb://nas.local/share"])
        XCTAssertEqual(model.chipsForTesting, ["Documents:thisMac"], "and Helm added no folder")
    }

    // MARK: A window with a plan waiting

    /// A window whose conversation answers with the organize plan, sent and waiting on its card. With
    /// `swapAfterMoving`, b.txt is replaced by another file as soon as a.txt has moved.
    private func windowWithPlan(wrap: ((any FileSystem) -> any FileSystem)? = nil, swapAfterMoving: Bool = false,
                                swapper: PanelSwapper? = nil) async throws -> (BrowserWindowController, AgentPanelModel, AgentChangePlan) {
        let (controller, box, _) = try await window(wrap: wrap)
        let plan = try await organizePlan(controller)
        box.plan = plan
        if swapAfterMoving, let swapper {
            let b = documents.appendingPathComponent("b.txt")
            swapper.arm(after: documents.appendingPathComponent("a.txt")) {
                // The new file exists before the old one goes, so it can't be given the old one's identity.
                let fresh = b.deletingLastPathComponent().appendingPathComponent("b.new")
                try? Data("a new b".utf8).write(to: fresh)
                try? FileManager.default.removeItem(at: b)
                try? FileManager.default.moveItem(at: fresh, to: b)
            }
        }
        let model = try await open(controller)
        model.type("tidy up")
        model.send()
        await settle(controller, model)
        XCTAssertEqual(model.phaseForTesting, "plan")
        return (controller, model, plan)
    }
}

/// Makes the conversation a test's panel talks to, with the plan and folder answers the test set by then.
final class PanelConversationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var planned: AgentChangePlan?
    private var answers: [String: AgentFolderRef] = [:]
    private var conversation: StandInConversation?
    var plan: AgentChangePlan? {
        get { lock.withLock { planned } }
        set { lock.withLock { planned = newValue } }
    }
    var folderAnswers: [String: AgentFolderRef] {
        get { lock.withLock { answers } }
        set { lock.withLock { answers = newValue } }
    }
    var made: StandInConversation? { lock.withLock { conversation } }
    func make() -> StandInConversation {
        lock.withLock {
            let made = StandInConversation(plan: planned)
            made.folderAnswers = answers
            conversation = made
            return made
        }
    }
}

/// Replaces a file once, right after another item has moved.
final class PanelSwapper: @unchecked Sendable {
    private let lock = NSLock()
    private var trigger: String?
    private var action: (() -> Void)?
    private var done = false
    var swapped: Bool { lock.withLock { done } }
    func arm(after url: URL, _ action: @escaping () -> Void) {
        lock.withLock { trigger = url.standardizedFileURL.path; self.action = action }
    }
    func moved(_ url: URL) {
        let run = lock.withLock { () -> (() -> Void)? in
            guard !done, url.standardizedFileURL.path == trigger else { return nil }
            done = true
            return action
        }
        run?()
    }
}

/// A file system that tells the swapper about every move it makes.
struct PanelSwappingFileSystem: FileSystem {
    let inner: any FileSystem
    let swapper: PanelSwapper
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        inner.enumerate(directory, options: options)
    }
    func entry(at url: URL) async throws -> FileEntry { try await inner.entry(at: url) }
    func exists(_ url: URL) async -> Bool { await inner.exists(url) }
    func isDirectory(_ url: URL, resolvingSymlinks: Bool) async -> Bool { await inner.isDirectory(url, resolvingSymlinks: resolvingSymlinks) }
    func childNames(of directory: URL) async throws -> Set<String> { try await inner.childNames(of: directory) }
    func mutationPrecondition(at source: URL) async throws -> FileMutationPrecondition { try await inner.mutationPrecondition(at: source) }
    func mutate(_ mutation: ConditionalFileMutation, source: URL, requiring precondition: FileMutationPrecondition) async throws -> URL? {
        let result = try await inner.mutate(mutation, source: source, requiring: precondition)
        if case .move = mutation { swapper.moved(source) }
        return result
    }
    func copyItem(at source: URL, to destination: URL) async throws { try await inner.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) async throws {
        try await inner.moveItem(at: source, to: destination)
        swapper.moved(source)
    }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws {
        try await inner.replaceItem(at: destination, with: temporary, backup: backup)
    }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws {
        try await inner.applyDirectoryMetadata(from: source, to: destination)
    }
    func trashItem(at url: URL) async throws -> URL? { try await inner.trashItem(at: url) }
    func removeItem(at url: URL) async throws { try await inner.removeItem(at: url) }
    func createDirectory(at url: URL) async throws { try await inner.createDirectory(at: url) }
    func createFileExclusively(at url: URL, contents: Data) async throws { try await inner.createFileExclusively(at: url, contents: contents) }
    func createSymbolicLink(at url: URL, destination: URL) async throws { try await inner.createSymbolicLink(at: url, destination: destination) }
    func createAlias(for url: URL, at destination: URL) async throws { try await inner.createAlias(for: url, at: destination) }
    func isCaseSensitive(at url: URL) async throws -> Bool { try await inner.isCaseSensitive(at: url) }
    func volumeIdentifier(for url: URL) async throws -> String { try await inner.volumeIdentifier(for: url) }
    func availableCapacity(of url: URL) async throws -> Int64 { try await inner.availableCapacity(of: url) }
    func sizeOfTree(at url: URL) -> AsyncThrowingStream<Int64, Error> { inner.sizeOfTree(at: url) }
    func makeMonitor(for directory: URL) -> any DirectoryMonitor { inner.makeMonitor(for: directory) }
    func reopenAfterStall() async -> Bool { await inner.reopenAfterStall() }
}

@MainActor final class PanelWindowHost: BrowserWindowHost {
    var aiScreenRequests = 0
    var settingsPanes: [SettingsPane] = []
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) { settingsPanes.append(pane) }
    func requestQuitAnyway() {}
    func showAIModeScreen(from window: BrowserWindowController?) { aiScreenRequests += 1 }
}
#endif
