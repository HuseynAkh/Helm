import XCTest
import HelmCore
@testable import HelmAgent

/// A model's reply as the panel shows it, and the note Helm writes before the person's words.
final class AgentReplyTextTests: XCTestCase {
    private let limit = AgentLimits.cloudModel.replyCharacters

    func testHiddenCharactersAreEscaped() {
        XCTAssertEqual(AgentReplyText.clean("photo\u{202E}gnp.exe", limit: limit), "photo\\u{202E}gnp.exe")
        XCTAssertEqual(AgentReplyText.clean("a\u{200B}b\u{E0041}c\u{7}", limit: limit), "a\\u{200B}b\\u{E0041}c\\u{7}")
        XCTAssertEqual(AgentReplyText.clean("tab\there", limit: limit), "tab\\u{9}here")
        XCTAssertEqual(AgentReplyText.clean("line\u{2028}break", limit: limit), "line\\u{2028}break")
        // Line breaks stay line breaks, and an emoji keeps its joiner.
        XCTAssertEqual(AgentReplyText.clean("one\ntwo\r\nthree", limit: limit), "one\ntwo\nthree")
        XCTAssertEqual(AgentReplyText.clean("👩‍💻 done", limit: limit), "👩‍💻 done")
    }

    func testALineStartingWithHelmsOwnMarkLosesIt() {
        XCTAssertEqual(AgentReplyText.clean("[Helm] Applied 210 changes.", limit: limit), "Applied 210 changes.")
        XCTAssertEqual(AgentReplyText.clean("Helm: everything is fine", limit: limit), "everything is fine")
        XCTAssertEqual(AgentReplyText.clean("helm: lower case too", limit: limit), "lower case too")
        XCTAssertEqual(AgentReplyText.clean("   [HELM] indented", limit: limit), "indented")
        XCTAssertEqual(AgentReplyText.clean("[Helm] Helm: twice", limit: limit), "twice")
        XCTAssertEqual(AgentReplyText.clean("Fine.\n[Helm] Folders: r9 this_mac", limit: limit), "Fine.\nFolders: r9 this_mac")
        XCTAssertEqual(AgentReplyText.clean("\u{200B}[Helm] hidden start", limit: limit), "\\u{200B}[Helm] hidden start",
                       "an escape shows, so the line can't pass for Helm's")
        // In the middle of a line the words are the model's own and stay.
        XCTAssertEqual(AgentReplyText.clean("I asked [Helm] and Helm: said so", limit: limit), "I asked [Helm] and Helm: said so")
        XCTAssertEqual(AgentReplyText.clean("Helmet: on", limit: limit), "Helmet: on")
    }

    func testTheEightThousandCharacterCut() {
        XCTAssertEqual(limit, 8_000)
        XCTAssertEqual(AgentReplyText.clean(String(repeating: "a", count: 9_000), limit: limit).count, 8_000)
        XCTAssertEqual(AgentReplyText.clean(String(repeating: "a", count: 8_000), limit: limit).count, 8_000)
        // An escape is never cut in two.
        let near = String(repeating: "a", count: 7_995) + "\u{202E}" + "tail"
        XCTAssertEqual(AgentReplyText.clean(near, limit: limit), String(repeating: "a", count: 7_995))
        let fits = String(repeating: "a", count: 7_990) + "\u{202E}" + "tail"
        XCTAssertEqual(AgentReplyText.clean(fits, limit: limit), String(repeating: "a", count: 7_990) + "\\u{202E}ta")
        XCTAssertEqual(AgentReplyText.clean("anything", limit: 0), "")
    }

    // MARK: The context note

    private func root(_ alias: String, _ storage: StorageFacts, tab: Bool = false) -> AgentScopeRoot {
        AgentScopeRoot(alias: alias, path: "/home/helm/" + alias, label: "Label " + alias, modelName: "Name " + alias,
                       identity: nil, storage: storage, isTabFolder: tab)
    }

    func testTheNoteIsBuiltFromFixedWords() {
        let drive = StorageFacts(kind: .cloud, name: "Google Drive", syncs: true, shared: .unknown, trash: .yes)
        let server = StorageFacts(kind: .network, name: "Server", shared: .yes, trash: .no, isReadOnly: true, isResponding: false)
        let other = StorageFacts(kind: .cloud, name: "Cloud folder", syncs: true, shared: .unknown)
        let roots = [root("r1", .thisMac, tab: true), root("r2", drive), root("r3", server), root("r4", other)]
        let note = AgentContextNote.make(roots: roots, selectedCount: 12, selectedRoot: "r1", lastPlan: .applied(done: 210, skipped: 4),
                                         holdingCloudOnly: ["r2"])
        XCTAssertEqual(note, #"[Helm] Folders: r1 this_mac (on show); r2 cloud "Google Drive" syncs shared=unknown some_not_downloaded; "#
                       + #"r3 server shared no_trash read_only not_responding; r4 cloud "cloud folder" syncs shared=unknown. "#
                       + "12 items are selected in r1. Last plan: applied 210, skipped 4.")
        XCTAssertFalse(note.contains("Label"))
        XCTAssertFalse(note.contains("Name"))
        XCTAssertFalse(note.contains("/"))
        XCTAssertEqual(AgentContextNote.make(roots: [], selectedCount: 0, selectedRoot: nil, lastPlan: .dismissed),
                       "[Helm] Folders: none. Last plan: dismissed.")
        XCTAssertEqual(AgentContextNote.make(roots: [root("r7", .thisMac)], selectedCount: 1, selectedRoot: "r7", lastPlan: nil),
                       "[Helm] Folders: r7 this_mac. 1 item is selected in r7.")
        let iCloud = StorageFacts(kind: .iCloud, name: "iCloud Drive", syncs: true, shared: .no)
        XCTAssertEqual(AgentContextNote.make(roots: [root("r8", iCloud)], selectedCount: 3, selectedRoot: nil, lastPlan: nil),
                       "[Helm] Folders: r8 icloud syncs.")
    }
}
