#if os(macOS)
import AppKit
import XCTest
import HelmAgent
import HelmCore
import HelmPersistence
@testable import HelmApp
@testable import HelmUI

/// The AI mode screen in a real app on a throwaway home: the welcome window's third mode, its one switch and one
/// button, what Done and every other way out leave behind, the panel it opens for the window that asked, and when it
/// opens by itself. The model answers from the scripted provider and keys stay in memory.
@MainActor final class AIModeScreenTests: XCTestCase {
    private var root: URL!
    private var app: AppController?
    /// Made up for these tests; never a real key.
    private let testKey = "test-key-for-the-ai-screen"

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-screen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/Documents", isDirectory: true),
                                                withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        app?.onboardingForTesting?.close()
        for window in app?.allWindows ?? [] { window.window?.close() }
        app = nil
        HeaderMotion.isDisabledForTesting = false
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func composedApp() async -> AppController {
        var options = LaunchOptions()
        options.home = root.appendingPathComponent("home", isDirectory: true)
        options.support = root.appendingPathComponent("support", isDirectory: true)
        let app = AppController(options: options)
        app.staysInBackground = true
        self.app = app
        await app.compose()
        return app
    }

    private func settings(_ app: AppController) throws -> SettingsStore { try XCTUnwrap(app.environment?.settings) }

    /// Waits for `condition`, generously, since a busy Mac is slow; a wait that is met ends at once.
    private func until(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// Presses Done as the button does, and waits for what it decided.
    private func pressDone(_ screen: OnboardingWindowController) async {
        XCTAssertTrue(screen.pressForTesting(AgentText.done))
        await screen.aiDoneWork?.value
    }

    /// Turns the switch on and enters a key, which the scripted provider then answers as connected.
    private func connect(_ model: AISetupModel) async {
        model.setOn(true)
        model.enterKey(testKey)
        await model.settle()
        XCTAssertEqual(model.connectionForTesting, "connected")
    }

    /// The AppKit controls SwiftUI draws the screen with, top to bottom.
    private func controls(in screen: OnboardingWindowController) -> [NSView] {
        guard let content = screen.window?.contentView else { return [] }
        content.layoutSubtreeIfNeeded()
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if view.isHiddenOrHasHiddenAncestor { return }
            if view is NSControl { found.append(view) }
            for child in view.subviews { walk(child) }
        }
        walk(content)
        return found.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    /// The kinds of AppKit control on show, top to bottom. SwiftUI draws its buttons itself, so a button never shows
    /// here: this finds any control the screen gains beyond the switch, the provider menu and the key field.
    private func controlKinds(in screen: OnboardingWindowController) -> [String] {
        controls(in: screen).map { view in
            switch view {
            case is NSSwitch: return "switch"
            case is NSPopUpButton: return "menu"
            case is NSSecureTextField: return "key"
            case is NSTextField: return "field"
            case is NSButton: return "button"
            default: return String(describing: Swift.type(of: view))
            }
        }
    }

    /// Presses Done from the keyboard, as Return does wherever the caret isn't in a field that takes Return itself:
    /// through the window's default button, which is Done. Then waits for what Done decided.
    private func pressDoneByKeyboard(_ screen: OnboardingWindowController) async throws {
        let window = try XCTUnwrap(screen.window)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                   charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(window.performKeyEquivalent(with: event), "Done is the window's default button")
        // The press starts Done's work at once, or a moment later; work that has already ended is not waited for.
        _ = await until(2) { screen.aiDoneWork != nil }
        await screen.aiDoneWork?.value
    }

    /// The keys the fixture run keeps in memory.
    private func secrets(_ app: AppController) throws -> MemorySecretStore {
        try XCTUnwrap(app.agentServicesForTesting?.secrets as? MemorySecretStore)
    }

    /// Types `text` into `field` as the keyboard does: the field takes the caret and its editor gets the characters.
    private func type(_ text: String, into field: NSTextField) -> Bool {
        guard let window = field.window, window.makeFirstResponder(field),
              let editor = field.currentEditor() as? NSTextView else { return false }
        editor.insertText(text, replacementRange: editor.selectedRange())
        return true
    }

    /// Return in `field`, as the keyboard sends it.
    private func pressReturn(in field: NSTextField) {
        (field.currentEditor() as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    /// Whether `field` has the caret: it, or the editor typing into it, is its window's first responder.
    private func hasCaret(_ field: NSTextField) -> Bool {
        guard let responder = field.window?.firstResponder else { return false }
        if responder === field { return true }
        return (responder as? NSTextView)?.delegate === field
    }

    // MARK: The screen

    func testTheAIModeIsAThirdModeOfTheWelcomeWindowWithOneSwitchAndOneButton() async throws {
        let app = await composedApp()
        app.access.showWelcome()
        let welcome = try XCTUnwrap(app.onboardingForTesting)
        XCTAssertEqual(welcome.modeForTesting, "setup")
        app.showAIModeScreen(from: nil)
        let screen = try XCTUnwrap(app.onboardingForTesting)
        XCTAssertTrue(screen === welcome, "the same window, in its third mode")
        XCTAssertEqual(screen.modeForTesting, "ai")
        XCTAssertEqual(screen.model.mode, .ai)
        XCTAssertEqual(screen.window?.title, AgentText.aiTitle)
        XCTAssertEqual(screen.window?.appearance?.name, .darkAqua, "the screen is always dark")
        XCTAssertTrue(screen.model.aiSetup === app.aiSetupModelForTesting)

        let model = try XCTUnwrap(app.aiSetupModelForTesting)
        XCTAssertEqual(AIModeScreen.parts(for: model), [.titleRow, .sentence, .done])
        XCTAssertEqual(AIModeScreen.buttonTitles(for: model), [AgentText.done], "Done is the only button")
        try await Task.sleep(nanoseconds: 200_000_000)
        var shown = controls(in: screen)
        XCTAssertEqual(shown.filter { $0 is NSSwitch }.count, 1)
        XCTAssertTrue(shown.first is NSSwitch, "the switch is in the title row, above everything else")
        XCTAssertEqual(controlKinds(in: screen), ["switch"], "no other control beside Done, which SwiftUI draws itself")

        // Once on: the provider menu, starting on Claude, and the key field, with still one button.
        model.setOn(true)
        XCTAssertEqual(AIModeScreen.parts(for: model), [.titleRow, .sentence, .provider, .key, .state, .consent, .done])
        XCTAssertEqual(AIModeScreen.buttonTitles(for: model), [AgentText.done])
        try await Task.sleep(nanoseconds: 300_000_000)
        shown = controls(in: screen)
        XCTAssertTrue(shown.first is NSSwitch)
        let menu = try XCTUnwrap(shown.compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(menu.titleOfSelectedItem, "Claude")
        XCTAssertEqual(menu.itemTitles, AgentProviderID.allCases.map(AgentProviderCatalog.name))
        XCTAssertEqual(shown.filter { $0 is NSSecureTextField }.count, 1, "the key field")
        XCTAssertEqual(shown.filter { $0 is NSSwitch }.count, 1)
        XCTAssertEqual(controlKinds(in: screen), ["switch", "menu", "key"], "and still no other button")
        let keyField = try XCTUnwrap(shown.compactMap { $0 as? NSSecureTextField }.first)
        let caretInKeyField = await until { self.hasCaret(keyField) }
        XCTAssertTrue(caretInKeyField, "the caret starts in the key field")
        XCTAssertTrue(model.linesForTesting.contains(AgentText.consent("Claude")))
        XCTAssertTrue(model.linesForTesting.contains(AgentText.stateNoKey))

        // Ollama shows its state in place of the key, with Try Again and the port while it isn't running.
        app.agentServicesForTesting?.runtime.scriptedClientForTesting?.modelsFailure = .notRunning
        model.choose(.ollama)
        await model.settle()
        XCTAssertEqual(AIModeScreen.parts(for: model), [.titleRow, .sentence, .provider, .state, .port, .consent, .done])
        XCTAssertEqual(AIModeScreen.buttonTitles(for: model), [AgentText.tryAgain, AgentText.done])
        app.agentServicesForTesting?.runtime.scriptedClientForTesting?.modelsFailure = nil
        model.press(AgentText.tryAgain)
        await model.settle()
        XCTAssertEqual(AIModeScreen.parts(for: model), [.titleRow, .sentence, .provider, .state, .consent, .done])
        XCTAssertEqual(AIModeScreen.buttonTitles(for: model), [AgentText.done])
    }

    func testAKeyTypedIntoTheFieldIsSavedUnderItsAddressTheFieldEmptiesAndItIsChecked() async throws {
        let app = await composedApp()
        let store = try secrets(app)
        app.showAIModeScreen(from: nil)
        let screen = try XCTUnwrap(app.onboardingForTesting)
        let model = try XCTUnwrap(app.aiSetupModelForTesting)
        model.setOn(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let field = try XCTUnwrap(controls(in: screen).compactMap { $0 as? NSSecureTextField }.first)
        XCTAssertTrue(type(testKey, into: field))
        pressReturn(in: field)
        let entered = await until { store.accounts == ["claude|api.anthropic.com:443"] }
        XCTAssertTrue(entered, "Return saved the key under its provider and address")
        await model.settle()
        XCTAssertEqual(model.connectionForTesting, "connected")
        let emptied = await until { field.stringValue.isEmpty }
        XCTAssertTrue(emptied, "the field is emptied once the key is entered")
        XCTAssertEqual(screen.modeForTesting, "ai", "Return enters the key; only Done closes")

        // Typed and not entered, Done enters it and empties the field; a key the provider turns down keeps it open.
        try store.remove(AgentSecretID(provider: .claude, host: "api.anthropic.com", port: 443))
        app.agentServicesForTesting?.runtime.scriptedClientForTesting?.modelsFailure = .wrongKey
        XCTAssertTrue(type(testKey, into: field))
        try await pressDoneByKeyboard(screen)
        XCTAssertEqual(store.accounts, ["claude|api.anthropic.com:443"], "Done entered the typed key")
        XCTAssertEqual(model.connectionForTesting, "wrongKey")
        XCTAssertEqual(screen.modeForTesting, "ai")
        let emptiedByDone = await until { field.stringValue.isEmpty }
        XCTAssertTrue(emptiedByDone, "Done empties the field as it hands the key over")
        let caretBack = await until { self.hasCaret(field) }
        XCTAssertTrue(caretBack, "the caret goes back to the key field")
    }

    func testAKeyTypedForOneProviderIsNeverSentToTheNext() async throws {
        let app = await composedApp()
        let store = try secrets(app)
        app.showAIModeScreen(from: nil)
        let screen = try XCTUnwrap(app.onboardingForTesting)
        let model = try XCTUnwrap(app.aiSetupModelForTesting)
        model.setOn(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let field = try XCTUnwrap(controls(in: screen).compactMap { $0 as? NSSecureTextField }.first)
        XCTAssertTrue(type(testKey, into: field))
        model.choose(.openAI)
        let emptied = await until { field.stringValue.isEmpty }
        XCTAssertTrue(emptied, "a change of provider empties the field")
        try await pressDoneByKeyboard(screen)
        XCTAssertEqual(store.accounts, [], "nothing was saved for OpenAI")
        XCTAssertEqual(model.connectionForTesting, "noKey")
        XCTAssertEqual(screen.modeForTesting, "ai")
    }

    func testAKeyTypedIntoSettingsIsSavedTheFieldEmptiesAndItIsChecked() async throws {
        let app = await composedApp()
        let store = try secrets(app)
        app.makeSettingsWindowIfNeeded()
        let settings = try XCTUnwrap(app.settingsControllerForTesting)
        defer { settings.close() }
        app.installAISettingsPane(in: settings)
        settings.select(.ai)
        let model = try XCTUnwrap(settings.aiSetupModel)
        model.setOn(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let content = try XCTUnwrap(settings.window?.contentView)
        content.layoutSubtreeIfNeeded()
        func secureFields(in view: NSView) -> [NSSecureTextField] {
            (view.isHiddenOrHasHiddenAncestor ? [] : [view].compactMap { $0 as? NSSecureTextField })
                + view.subviews.flatMap(secureFields)
        }
        let field = try XCTUnwrap(secureFields(in: content).first, "Settings › AI's key field")
        XCTAssertTrue(type(testKey, into: field))
        pressReturn(in: field)
        let entered = await until { store.accounts == ["claude|api.anthropic.com:443"] }
        XCTAssertTrue(entered, "Return saved the key under its provider and address")
        await model.settle()
        XCTAssertEqual(model.connectionForTesting, "connected")
        let emptied = await until { field.stringValue.isEmpty }
        XCTAssertTrue(emptied, "the field is emptied once the key is entered")

        // A key typed for one provider is dropped when another is picked, so Return can't save it for that one.
        XCTAssertTrue(type(testKey, into: field))
        model.choose(.openAI)
        let dropped = await until { field.stringValue.isEmpty }
        XCTAssertTrue(dropped, "a change of provider empties the field")
        pressReturn(in: field)
        await model.settle()
        XCTAssertEqual(store.accounts, ["claude|api.anthropic.com:443"], "nothing was saved for OpenAI")
        XCTAssertEqual(model.connectionForTesting, "noKey")
    }

    func testAKeyTypedIntoSettingsIsEnteredWhenTheFieldLosesFocus() async throws {
        let app = await composedApp()
        let store = try secrets(app)
        app.makeSettingsWindowIfNeeded()
        let settings = try XCTUnwrap(app.settingsControllerForTesting)
        defer { settings.close() }
        app.installAISettingsPane(in: settings)
        settings.select(.ai)
        let model = try XCTUnwrap(settings.aiSetupModel)
        model.setOn(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let content = try XCTUnwrap(settings.window?.contentView)
        content.layoutSubtreeIfNeeded()
        func secureFields(in view: NSView) -> [NSSecureTextField] {
            (view.isHiddenOrHasHiddenAncestor ? [] : [view].compactMap { $0 as? NSSecureTextField })
                + view.subviews.flatMap(secureFields)
        }
        let field = try XCTUnwrap(secureFields(in: content).first, "Settings › AI's key field")
        XCTAssertTrue(type(testKey, into: field))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(settings.window?.makeFirstResponder(nil) == true)
        let entered = await until { store.accounts == ["claude|api.anthropic.com:443"] }
        XCTAssertTrue(entered, "leaving the field entered the key, as Return does")
        await model.settle()
        XCTAssertEqual(model.connectionForTesting, "connected")
    }

    func testDoneWithTheSwitchOffClosesAndLeavesAIModeOff() async throws {
        let app = await composedApp()
        let settings = try settings(app)
        app.showAIModeScreen(from: nil)
        let screen = try XCTUnwrap(app.onboardingForTesting)
        await pressDone(screen)
        XCTAssertEqual(screen.modeForTesting, "closed")
        XCTAssertFalse(settings.snapshot.bool(.aiModeEnabled))
        XCTAssertTrue(settings.snapshot.bool(.aiIntroSeen))
    }

    func testDoneWhileConnectedClosesAndLeavesAIModeOn() async throws {
        let app = await composedApp()
        let settings = try settings(app)
        app.showAIModeScreen(from: nil)
        let screen = try XCTUnwrap(app.onboardingForTesting)
        await connect(try XCTUnwrap(app.aiSetupModelForTesting))
        await pressDone(screen)
        XCTAssertEqual(screen.modeForTesting, "closed")
        XCTAssertTrue(settings.snapshot.bool(.aiModeEnabled), "only Done leaves AI mode on")
        XCTAssertTrue(settings.snapshot.bool(.aiIntroSeen))
        XCTAssertTrue(app.agentServicesForTesting?.runtime.isOn ?? false)
    }

    func testDoneWhileNotConnectedStaysOpen() async throws {
        let app = await composedApp()
        let settings = try settings(app)
        app.showAIModeScreen(from: nil)
        let screen = try XCTUnwrap(app.onboardingForTesting)
        let model = try XCTUnwrap(app.aiSetupModelForTesting)
        model.setOn(true)
        XCTAssertEqual(model.connectionForTesting, "noKey")
        await pressDone(screen)
        XCTAssertEqual(screen.modeForTesting, "ai", "the state stays on show")
        XCTAssertFalse(settings.snapshot.bool(.aiIntroSeen), "staying isn't a way out")
        // A key the provider turns down keeps it open too.
        app.agentServicesForTesting?.runtime.scriptedClientForTesting?.modelsFailure = .wrongKey
        model.enterKey(testKey)
        await model.settle()
        await pressDone(screen)
        XCTAssertEqual(model.connectionForTesting, "wrongKey")
        XCTAssertEqual(screen.modeForTesting, "ai")
        XCTAssertTrue(settings.snapshot.bool(.aiModeEnabled))
    }

    func testEveryOtherWayOutTurnsAIModeOffAndMarksItSeen() async throws {
        let app = await composedApp()
        let settings = try settings(app)
        let model = try XCTUnwrap(app.aiSetupModelForTesting)
        func reset() {
            settings.set(.bool(false), for: .aiIntroSeen)
            app.showAIModeScreen(from: nil)
            model.setOn(true)
            XCTAssertTrue(settings.snapshot.bool(.aiModeEnabled))
        }
        // The window's close button.
        reset()
        let screen = try XCTUnwrap(app.onboardingForTesting)
        screen.window?.performClose(nil)
        XCTAssertEqual(screen.modeForTesting, "closed")
        XCTAssertFalse(settings.snapshot.bool(.aiModeEnabled))
        XCTAssertTrue(settings.snapshot.bool(.aiIntroSeen))
        // Even when connected: only Done leaves it on.
        reset()
        await connect(model)
        screen.close()
        XCTAssertFalse(settings.snapshot.bool(.aiModeEnabled))
        XCTAssertTrue(settings.snapshot.bool(.aiIntroSeen))
        // Quitting with it open.
        reset()
        app.access.quitting()
        XCTAssertFalse(settings.snapshot.bool(.aiModeEnabled))
        XCTAssertTrue(settings.snapshot.bool(.aiIntroSeen))
        screen.close()
        // Help › Set Up Helm… while it is open: the checklist takes its place.
        reset()
        app.access.showWelcome()
        XCTAssertEqual(screen.modeForTesting, "setup")
        XCTAssertNil(screen.model.aiSetup)
        XCTAssertNil(screen.window?.appearance, "the checklist follows the Mac's appearance")
        XCTAssertFalse(settings.snapshot.bool(.aiModeEnabled))
        XCTAssertTrue(settings.snapshot.bool(.aiIntroSeen))
    }

    // MARK: The panel

    func testFromAWindowsSparkDoneWhileConnectedOpensThatWindowsPanel() async throws {
        let app = await composedApp()
        let window = try XCTUnwrap(app.allWindows.first)
        var opened: [BrowserWindowController] = []
        app.access.openAgentPanel = { opened.append($0) }
        // The spark, while no model is ready, asks for the screen.
        window.toggleAgentPanel()
        let screen = try XCTUnwrap(app.onboardingForTesting)
        XCTAssertEqual(screen.modeForTesting, "ai")
        let model = try XCTUnwrap(app.aiSetupModelForTesting)
        await connect(model)
        await pressDone(screen)
        XCTAssertEqual(screen.modeForTesting, "closed")
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first === window, "the panel opens in the window whose spark asked")

        // Done with the switch off opens nothing.
        window.toggleAgentPanel()
        XCTAssertEqual(opened.count, 1, "a ready model's spark toggles the panel, not the screen")
        app.showAIModeScreen(from: window)
        model.setOn(false)
        await pressDone(screen)
        XCTAssertEqual(opened.count, 1)

        // Shown at launch, with no window asking, Done opens the panel in the window in front.
        app.showAIModeScreen(from: nil)
        await connect(model)
        await pressDone(screen)
        XCTAssertEqual(screen.modeForTesting, "closed")
        XCTAssertEqual(opened.count, 2)
        XCTAssertTrue(opened.last === window, "the only window is the one in front")
    }

    func testAfterSetupDoneWhileConnectedOpensThePanelInTheFrontWindow() async throws {
        let app = await composedApp()
        let settings = try settings(app)
        app.access.opensAIIntroForTesting = true
        app.newWindow(nil)
        XCTAssertEqual(app.allWindows.count, 2)
        let front = try XCTUnwrap(app.frontmost())
        let other = try XCTUnwrap(app.allWindows.first { $0 !== front })
        // The checklist closes and the AI mode screen follows, with no window asking.
        app.access.showWelcome()
        let screen = try XCTUnwrap(app.onboardingForTesting)
        app.showAIIntroIfNeeded()
        XCTAssertTrue(screen.pressForTesting("Not Now"))
        let followed = await until { screen.modeForTesting == "ai" }
        XCTAssertTrue(followed)
        let model = try XCTUnwrap(app.aiSetupModelForTesting)
        await connect(model)
        await pressDone(screen)
        XCTAssertEqual(screen.modeForTesting, "closed")
        XCTAssertTrue(settings.snapshot.bool(.aiModeEnabled))
        let open = await until { front.isAgentPanelOpen }
        XCTAssertTrue(open, "Done opened the panel in the window in front")
        XCTAssertFalse(other.isAgentPanelOpen, "and only there")
    }

    func testAfterSetupClosingTheScreenAnyOtherWayOpensNoPanel() async throws {
        let app = await composedApp()
        let settings = try settings(app)
        app.access.opensAIIntroForTesting = true
        settings.set(.bool(true), for: .onboardingCompleted)
        let window = try XCTUnwrap(app.allWindows.first)
        app.showAIIntroIfNeeded()
        let screen = try XCTUnwrap(app.onboardingForTesting)
        XCTAssertEqual(screen.modeForTesting, "ai")
        let model = try XCTUnwrap(app.aiSetupModelForTesting)
        await connect(model)
        screen.window?.performClose(nil)
        XCTAssertFalse(settings.snapshot.bool(.aiModeEnabled))
        XCTAssertFalse(window.isAgentPanelOpen)
    }

    func testDoneOpensTheRealPanelAndClosingTheScreenLeavesAIModeOff() async throws {
        let app = await composedApp()
        let settings = try settings(app)
        let window = try XCTUnwrap(app.allWindows.first)
        // Closed with the switch on, the screen leaves AI mode off and no panel opens.
        window.toggleAgentPanel()
        let screen = try XCTUnwrap(app.onboardingForTesting)
        let model = try XCTUnwrap(app.aiSetupModelForTesting)
        model.setOn(true)
        screen.window?.performClose(nil)
        XCTAssertFalse(settings.snapshot.bool(.aiModeEnabled))
        XCTAssertFalse(window.isAgentPanelOpen)
        // Done while connected opens the window's own panel, with nothing standing in for it.
        window.toggleAgentPanel()
        XCTAssertEqual(screen.modeForTesting, "ai")
        await connect(model)
        await pressDone(screen)
        XCTAssertEqual(screen.modeForTesting, "closed")
        XCTAssertTrue(settings.snapshot.bool(.aiModeEnabled))
        let open = await until { window.isAgentPanelOpen }
        XCTAssertTrue(open, "Done opened the panel in the window whose spark asked")
    }

    // MARK: Opening by itself

    func testItNeverOpensByItselfInAFixtureRun() async throws {
        let app = await composedApp()
        XCTAssertNil(app.onboardingForTesting, "nothing opened at launch")
        let settings = try settings(app)
        settings.set(.bool(true), for: .onboardingCompleted)
        app.showAIIntroIfNeeded()
        XCTAssertNotEqual(app.onboardingForTesting?.modeForTesting, "ai")
        XCTAssertFalse(settings.snapshot.bool(.aiIntroSeen))
    }

    func testItOpensOnceAtLaunchForSomeoneWhoSetUpHelmBefore() async throws {
        let app = await composedApp()
        let settings = try settings(app)
        app.access.opensAIIntroForTesting = true
        // A first launch that hasn't been through the checklist: not yet.
        app.showAIIntroIfNeeded()
        XCTAssertNil(app.onboardingForTesting)
        settings.set(.bool(true), for: .onboardingCompleted)
        app.showAIIntroIfNeeded()
        let screen = try XCTUnwrap(app.onboardingForTesting)
        XCTAssertEqual(screen.modeForTesting, "ai")
        screen.close()
        XCTAssertTrue(settings.snapshot.bool(.aiIntroSeen))
        // Seen, so the next launch leaves it shut.
        app.showAIIntroIfNeeded()
        XCTAssertEqual(screen.modeForTesting, "closed")
    }

    func testOnTheFirstLaunchItOpensWhenTheChecklistCloses() async throws {
        let app = await composedApp()
        let settings = try settings(app)
        app.access.opensAIIntroForTesting = true
        app.access.showWelcome()
        let screen = try XCTUnwrap(app.onboardingForTesting)
        app.showAIIntroIfNeeded()
        XCTAssertEqual(screen.modeForTesting, "setup", "the checklist comes first")
        XCTAssertTrue(screen.pressForTesting("Not Now"))
        XCTAssertTrue(settings.snapshot.bool(.onboardingCompleted))
        let followed = await until { screen.modeForTesting == "ai" }
        XCTAssertTrue(followed, "the AI mode screen follows the checklist")
        screen.close()
        XCTAssertTrue(settings.snapshot.bool(.aiIntroSeen))
    }

    // MARK: Settings › AI

    func testSettingsAndTheScreenShareOneModel() async throws {
        let app = await composedApp()
        app.makeSettingsWindowIfNeeded()
        let settings = try XCTUnwrap(app.settingsControllerForTesting)
        defer { settings.close() }
        XCTAssertNil(settings.aiSetupModel, "the pane is empty until the app gives it its model")
        app.installAISettingsPane(in: settings)
        let model = try XCTUnwrap(settings.aiSetupModel)
        XCTAssertTrue(model === app.aiSetupModelForTesting)
        app.installAISettingsPane(in: settings)
        XCTAssertTrue(settings.aiSetupModel === model, "installed once")
        let tabs = try XCTUnwrap(settings.window?.contentViewController as? NSTabViewController)
        XCTAssertEqual(tabs.tabViewItems[1].label, "AI")
        XCTAssertNotNil(tabs.tabViewItems[1].image, "the tab keeps its spark")
        app.showAIModeScreen(from: nil)
        XCTAssertTrue(app.onboardingForTesting?.model.aiSetup === model)
        XCTAssertEqual(app.agentServicesForTesting?.runtime.clientBuildCount, 0)
    }

    // MARK: The checklist

    func testTheChecklistHeaderReadsTheNewLine() async throws {
        let app = await composedApp()
        app.access.showWelcome()
        let screen = try XCTUnwrap(app.onboardingForTesting)
        XCTAssertEqual(screen.model.headerLine, AgentText.setupHeader)
        XCTAssertEqual(screen.model.headerLine, "Nothing leaves your Mac unless you turn on AI mode.")
        screen.close()
        app.access.showGuide(.fullDiskAccess)
        XCTAssertEqual(screen.modeForTesting, "guide")
        XCTAssertNil(screen.model.headerLine, "the guide's header names its one row")
    }
}
#endif
