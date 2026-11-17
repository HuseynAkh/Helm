import XCTest
import HelmCore
import HelmTestKit
@testable import HelmAgent

/// Whole Mac's words, pinned as every other AI mode sentence is, its prompt, and the disks the runtime hands each
/// conversation.
final class AgentWholeMacTextTests: XCTestCase {
    private typealias Row = (key: String, text: String, expected: String)

    private static let rows: [Row] = [
        ("scopeSwitchLabel", AgentText.scopeSwitchLabel, "Where AI mode looks"),
        ("scopeThisFolder", AgentText.scopeThisFolder, "This Folder"),
        ("scopeWholeMac", AgentText.scopeWholeMac, "Whole Mac"),
        ("scopeSwitchHelp", AgentText.scopeSwitchHelp, "Whole Mac lets AI mode look through your home folder, cloud folders and disks."),
        ("chipWholeMac", AgentText.chipWholeMac, "Your home folder, iCloud Drive, cloud folders and disks."),
        ("consentWholeMac", AgentText.consentWholeMac("Claude"),
         "Sends your requests and file names from your home folder and disks to Claude, never file contents.")
    ]

    func testEverySentenceIsWordForWordAndOneSentenceAtMost() {
        for row in Self.rows {
            XCTAssertEqual(row.text, row.expected, row.key)
            XCTAssertFalse(row.text.contains("\""), row.key)
            for end in [". ", "? ", "! "] { XCTAssertFalse(row.text.contains(end), row.key) }
        }
    }

    func testTheConsentLineNamesTheHomeFolderAndDisksAndSaysWhereRequestsGoAsTheOtherDoes() {
        XCTAssertEqual(AgentText.consentWholeMac(AgentText.destinationOnThisMac("LM Studio")),
                       "Sends your requests and file names from your home folder and disks to LM Studio on this Mac, never file contents.")
        XCTAssertEqual(AgentText.consentWholeMac("Clau\u{0}de"),
                       "Sends your requests and file names from your home folder and disks to Clau\\u{0}de, never file contents.")
        XCTAssertEqual(AgentText.consent("Claude"), "Sends your requests and file names to Claude, never file contents.",
                       "This Folder's line is as it was")
    }

    func testTheWholeMacPromptIsTheUsualOneThenWhatWholeMacAdds() {
        XCTAssertTrue(AgentPrompt.wholeMac.hasPrefix(AgentPrompt.system + " "))
        XCTAssertFalse(AgentPrompt.wholeMac.contains("\n"))
        XCTAssertLessThan(AgentPrompt.wholeMac.split(separator: " ").count, 300)
        let added = String(AgentPrompt.wholeMac.dropFirst(AgentPrompt.system.count + 1))
        XCTAssertTrue(added.hasPrefix("Whole Mac is on"))
        XCTAssertTrue(added.contains("use list_folder on the likely destinations, such as Pictures"))
        XCTAssertTrue(added.contains("Keep things that already belong where they are"))
        XCTAssertTrue(added.contains("marked home"), "the word the note puts on the home folder")
        XCTAssertFalse(added.contains("/"), "no path")
        XCTAssertFalse(AgentPrompt.system.contains("Whole Mac"), "This Folder's prompt is as it was")
    }

    @MainActor func testTheRuntimeHandsEachConversationTheDisksMounted() async throws {
        let made = AgentWholeMacPartsBox()
        let runtime = AgentRuntime(parts: AgentRuntimeParts(
            secrets: MemorySecretStore(), disk: MemoryAgentDisk(), home: "/home/helm", supportFolder: "/home/helm/.helm-support",
            clock: FakeClock(), buildStamp: "", scripted: ScriptedModelClient(),
            makeSession: { parts in made.parts = parts; return StandInConversation() },
            mountedVolumes: { ["/Volumes/Backup"] }))
        runtime.setOn(true)
        XCTAssertNotNil(runtime.makeSession())
        let parts = try XCTUnwrap(made.parts)
        let mounted = await parts.mountedVolumes()
        XCTAssertEqual(mounted, ["/Volumes/Backup"])
        // Parts made without saying give none, so a test or a stand-in never reaches a real disk.
        let plain = AgentSessionParts(client: { .failure(.off) }, disk: MemoryAgentDisk(), home: "/home/helm",
                                      supportFolder: "/home/helm/.helm-support", clock: FakeClock())
        let none = await plain.mountedVolumes()
        XCTAssertEqual(none, [])
    }
}

/// What the runtime handed the last conversation it made.
private final class AgentWholeMacPartsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var held: AgentSessionParts?
    var parts: AgentSessionParts? {
        get { lock.lock(); defer { lock.unlock() }; return held }
        set { lock.lock(); defer { lock.unlock() }; held = newValue }
    }
}
