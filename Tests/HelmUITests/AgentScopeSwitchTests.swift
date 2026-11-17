#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import HelmAgent
import HelmCore
@testable import HelmUI

/// The folders row's switch: This Folder for every new thread, Whole Mac starting the thread over with the consent
/// line naming the home folder and one chip for its places, a new thread of any kind back in This Folder, and no
/// switching while a request runs.
@MainActor final class AgentScopeSwitchTests: XCTestCase {
    private let folder = "/home/helm/Downloads"

    private func model(_ conversation: any AgentConversing) async -> AgentPanelModel {
        let model = AgentPanelModel(session: conversation, home: "/home/helm",
                                    provider: AgentPanelModel.Provider(name: "Claude", destination: "Claude", model: "scripted-1"))
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

    private func lines(_ model: AgentPanelModel) -> [String] { model.threadTextForTesting.components(separatedBy: "\n") }

    func testThisFolderIsWhereEveryPanelStartsAndIsAsItWas() async {
        let model = await model(StandInConversation())
        XCTAssertEqual(model.scopeForTesting, "thisFolder")
        XCTAssertEqual(lines(model).first, AgentText.consent("Claude"))
        XCTAssertEqual(model.chipsForTesting, ["Downloads:thisMac"])
        XCTAssertTrue(model.canChooseScope)
    }

    func testWholeMacStartsOverNamesTheHomeFolderAndShowsOneChip() async {
        let conversation = StandInConversation()
        let model = await model(conversation)
        model.chooseScope(.wholeMac)
        // The conversation's own word that the thread started over reaches the panel on its own path.
        let startedOver = await until { self.lines(model).contains(AgentText.noticeStartedOver) && !model.isWaitingForTesting }
        XCTAssertTrue(startedOver)
        XCTAssertEqual(model.scopeForTesting, "wholeMac")
        let thread = lines(model)
        XCTAssertEqual(thread.first, AgentText.consentWholeMac("Claude"))
        XCTAssertEqual(thread.filter { $0 == AgentText.noticeStartedOver }.count, 1, "said once")
        XCTAssertFalse(thread.contains(AgentText.consent("Claude")))
        XCTAssertEqual(model.chipsForTesting, ["Downloads:thisMac", "Whole Mac:thisMac"])
        let wholeMac = model.chips.last
        XCTAssertEqual(wholeMac?.removable, false, "the switch takes it away, not a close button")
        XCTAssertEqual(wholeMac?.tooltip, AgentText.chipWholeMac)
        let mode = await conversation.scopeMode()
        XCTAssertEqual(mode, .wholeMac)

        model.chooseScope(.thisFolder)
        await settle(model)
        XCTAssertEqual(model.scopeForTesting, "thisFolder")
        XCTAssertEqual(lines(model).first, AgentText.consent("Claude"))
        XCTAssertEqual(model.chipsForTesting, ["Downloads:thisMac"])
    }

    func testANewThreadOfAnyKindIsBackInThisFolder() async {
        let conversation = StandInConversation()
        let model = await model(conversation)
        model.chooseScope(.wholeMac)
        await settle(model)
        model.type("/clear")
        model.send()
        await settle(model)
        XCTAssertEqual(model.scopeForTesting, "thisFolder", "/clear")
        XCTAssertEqual(lines(model).first, AgentText.consent("Claude"))

        model.chooseScope(.wholeMac)
        await settle(model)
        // A change of provider starts the thread over from outside the panel.
        await conversation.startOver()
        let back = await until { model.scopeForTesting == "thisFolder" && !model.isWaitingForTesting }
        XCTAssertTrue(back, "a change of provider")
        XCTAssertEqual(lines(model).first, AgentText.consent("Claude"))
        XCTAssertEqual(model.chipsForTesting, ["Downloads:thisMac"])
    }

    func testTheSwitchWaitsWhileARequestRuns() async {
        let conversation = PanelTestConversation()
        let gate = PanelTestGate()
        conversation.gate = gate
        let model = await model(conversation)
        model.type("hello")
        model.send()
        _ = await until { model.phase == .working }
        XCTAssertFalse(model.canChooseScope)
        model.chooseScope(.wholeMac)
        XCTAssertEqual(model.scopeForTesting, "thisFolder")
        gate.open()
        await settle(model)
        XCTAssertTrue(model.canChooseScope)
    }

    func testTheSwitchDrawsInTheFoldersRow() {
        let model = AgentPanelModel()
        let host = NSHostingView(rootView: AgentPanelView(model: model).frame(width: 340, height: 400))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        let picker = NSHostingView(rootView: AgentScopeSwitch(model: model))
        picker.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(picker.fittingSize.width, 60, "both halves have room")
    }
}
#endif
