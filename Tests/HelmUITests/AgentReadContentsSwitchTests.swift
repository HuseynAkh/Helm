#if os(macOS)
import AppKit
import XCTest
import HelmAgent
import HelmCore
@testable import HelmUI

/// The Read contents switch beside the composer: off for every new thread, on starting the thread over with the
/// consent line saying what is read and where it goes, kept by the scope switch, off again for a new thread, never
/// switched while a request runs, and drawn only in a run that can read inside files.
@MainActor final class AgentReadContentsSwitchTests: XCTestCase {
    private let folder = "/home/helm/Downloads"

    private func model(_ conversation: any AgentConversing, isLocal: Bool = false, offers: Bool = true) async -> AgentPanelModel {
        let destination = isLocal ? AgentText.destinationOnThisMac("Ollama") : "Claude"
        let model = AgentPanelModel(session: conversation, home: "/home/helm",
                                    provider: AgentPanelModel.Provider(name: isLocal ? "Ollama" : "Claude", destination: destination,
                                                                       model: "scripted-1", isLocal: isLocal),
                                    offersReadContents: offers)
        model.update(tab: AgentPanelModel.TabContext(folder: folder, itemCount: 5, selectedPaths: []))
        let ready = await until { model.phase == .idle && !model.isWaitingForTesting }
        XCTAssertTrue(ready, "the tab's folder never arrived")
        return model
    }

    private func until(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func settle(_ model: AgentPanelModel) async { _ = await until { !model.isWaitingForTesting } }
    private func first(_ model: AgentPanelModel) -> String? { model.threadTextForTesting.components(separatedBy: "\n").first }

    func testTheConsentLines() {
        let cloud = AgentPanelModel.Provider(name: "Claude", destination: "Claude", model: "m")
        let local = AgentPanelModel.Provider(name: "Ollama", destination: "Ollama on this Mac", model: "m", isLocal: true)
        XCTAssertEqual(AgentPanelModel.consentLine(cloud, .thisFolder, readsContents: false),
                       "Sends your requests and file names to Claude, never file contents.")
        XCTAssertEqual(AgentPanelModel.consentLine(cloud, .thisFolder, readsContents: true),
                       "Sends your requests, file names and short summaries of file contents to Claude.")
        XCTAssertEqual(AgentPanelModel.consentLine(cloud, .wholeMac, readsContents: true),
                       "Sends your requests, file names and short summaries of file contents from your home folder and disks to Claude.")
        XCTAssertEqual(AgentPanelModel.consentLine(local, .thisFolder, readsContents: true),
                       "Reads file contents on this Mac; nothing leaves your Mac.")
        XCTAssertEqual(AgentPanelModel.consentLine(local, .wholeMac, readsContents: true),
                       "Reads file names and contents from your home folder and disks on this Mac; nothing leaves your Mac.")
        XCTAssertEqual(AgentPanelModel.consentLine(local, .thisFolder, readsContents: false),
                       "Sends your requests and file names to Ollama on this Mac, never file contents.")
        // A name with a hidden character in it is written out, as every destination is.
        let other = AgentPanelModel.Provider(name: "x", destination: "evil\u{202E}host", model: "m")
        XCTAssertTrue(AgentPanelModel.consentLine(other, .thisFolder, readsContents: true).contains("\\u{202E}"))
    }

    func testOnStartsOverWithTheConsentLineForTheProvider() async {
        let conversation = StandInConversation()
        let model = await model(conversation)
        XCTAssertEqual(model.readsContentsForTesting, "off")
        XCTAssertEqual(first(model), AgentText.consent("Claude"))
        model.chooseReadsContents(true)
        let startedOver = await until { model.threadTextForTesting.contains(AgentText.noticeStartedOver) && !model.isWaitingForTesting }
        XCTAssertTrue(startedOver)
        XCTAssertEqual(model.readsContentsForTesting, "on")
        agentUIEqual(await conversation.readsContents(), true)
        XCTAssertEqual(first(model), AgentText.consentContents("Claude"))

        let local = await self.model(StandInConversation(), isLocal: true)
        local.chooseReadsContents(true)
        await settle(local)
        XCTAssertEqual(first(local), AgentText.consentContentsOnThisMac)
    }

    func testTheScopeSwitchKeepsItAndANewThreadTurnsItOff() async {
        let conversation = StandInConversation()
        let model = await model(conversation)
        model.chooseReadsContents(true)
        await settle(model)
        model.chooseScope(.wholeMac)
        await settle(model)
        XCTAssertEqual(model.readsContentsForTesting, "on")
        XCTAssertEqual(first(model), AgentText.consentContentsWholeMac("Claude"))
        model.type("/clear")
        model.send()
        await settle(model)
        XCTAssertEqual(model.readsContentsForTesting, "off")
        XCTAssertEqual(first(model), AgentText.consent("Claude"))
        model.chooseReadsContents(true)
        await settle(model)
        // A change of provider starts the thread over from outside the panel.
        await conversation.startOver()
        let off = await until { model.readsContentsForTesting == "off" && !model.isWaitingForTesting }
        XCTAssertTrue(off)
        XCTAssertEqual(first(model), AgentText.consent("Claude"))
    }

    func testTheSwitchWaitsWhileARequestRunsAndIsAbsentWhereNothingCanBeRead() async {
        let conversation = PanelTestConversation()
        let gate = PanelTestGate()
        conversation.gate = gate
        let model = await model(conversation)
        model.type("hello")
        model.send()
        _ = await until { model.phase == .working }
        model.chooseReadsContents(true)
        XCTAssertEqual(model.readsContentsForTesting, "off")
        gate.open()
        await settle(model)

        let none = await self.model(StandInConversation(), offers: false)
        none.chooseReadsContents(true)
        await settle(none)
        XCTAssertEqual(none.readsContentsForTesting, "off")
    }

    func testTheComposerDrawsTheSwitchAndAPressTurnsItOn() async {
        let conversation = StandInConversation()
        let model = await model(conversation)
        let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 340, height: 80))
        let host = AgentPanelHost()
        composer.attach(model, dropTarget: host)
        composer.layoutSubtreeIfNeeded()
        XCTAssertEqual(composer.contentsToggleForTesting.shown, true)
        XCTAssertEqual(composer.contentsToggleForTesting.on, false)
        XCTAssertEqual(composer.contentsToggle.accessibilityLabel(), AgentText.readContents)
        XCTAssertEqual(composer.contentsToggle.accessibilityRole(), .checkBox)
        XCTAssertEqual(composer.contentsToggle.toolTip, AgentText.readContentsHelp)
        composer.pressContentsToggleForTesting()
        let on = await until { model.readsContentsForTesting == "on" && !model.isWaitingForTesting }
        XCTAssertTrue(on)
        let drawn = await until { composer.contentsToggleForTesting.on }
        XCTAssertTrue(drawn)

        let without = await self.model(StandInConversation(), offers: false)
        let other = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 340, height: 80))
        other.attach(without, dropTarget: host)
        XCTAssertEqual(other.contentsToggleForTesting.shown, false)
    }

    func testTheKindRowDrawsTheSwitchAtItsEndAndMakesRoomForIt() {
        let bar = SearchKindBar(frame: NSRect(x: 0, y: 0, width: 700, height: SearchKindBar.height))
        var pressed: [Bool] = []
        bar.onContents = { pressed.append($0) }
        bar.showContents(offered: true, on: false)
        bar.setShown(true)
        bar.setFrameSize(NSSize(width: 700, height: SearchKindBar.height))
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.contentsForTesting.shown, true)
        XCTAssertTrue(bar.clickContentsForTesting())
        XCTAssertEqual(pressed, [true])
        // Every choice and the switch fit in the narrowest window, without overlapping.
        let lastChip = bar.chips.last.map { $0.convert($0.bounds, to: bar) } ?? .zero
        let toggle = bar.contentsToggle.convert(bar.contentsToggle.bounds, to: bar)
        XCTAssertLessThanOrEqual(lastChip.maxX, toggle.minX, "\(lastChip) \(toggle)")
        XCTAssertLessThanOrEqual(toggle.maxX, 700)
        bar.showContents(offered: false, on: false)
        XCTAssertEqual(bar.contentsForTesting.shown, false)
        XCTAssertFalse(bar.clickContentsForTesting())
    }
}

/// XCTest's assertions take their values as autoclosures, which can't wait.
@MainActor func agentUIEqual<Value: Equatable>(_ value: Value, _ expected: Value, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(value, expected, file: file, line: line)
}
#endif
