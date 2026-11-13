import XCTest
import HelmCore
@testable import HelmAgent

/// What the text in the composer asks for: a command, a folder to add, a server to connect to, or a message.
final class AgentComposerIntentTests: XCTestCase {
    private func parse(_ text: String) -> AgentComposerIntent { AgentComposerIntent.parse(text) }

    /// A stand-in shaped like a provider's key, put together here so no line of this file is shaped like one.
    private let keyShaped = "sk-" + String(repeating: "aB3", count: 10)

    func testNothingTyped() {
        XCTAssertEqual(parse(""), .empty)
        XCTAssertEqual(parse("   "), .empty)
        XCTAssertEqual(parse(" \n\t "), .empty)
    }

    // MARK: Commands

    func testAddTakesAFolder() {
        XCTAssertEqual(parse("/add ~/Pictures"), .add("~/Pictures"))
        XCTAssertEqual(parse("/add /Volumes/Photos 2026/Trips"), .add("/Volumes/Photos 2026/Trips"))
        XCTAssertEqual(parse("  /add    ~/Pictures/My Trip  "), .add("~/Pictures/My Trip"))
        XCTAssertEqual(parse("/add file:///home/helm/Documents"), .add("file:///home/helm/Documents"))
        // Whatever follows is the folder as typed. Whether there is such a folder is for the scope rules to say.
        XCTAssertEqual(parse("/add Documents"), .add("Documents"))
        XCTAssertEqual(parse("/add"), .add(""))
        XCTAssertEqual(parse("/ADD ~/Pictures"), .add("~/Pictures"))
        XCTAssertEqual(parse("/Add\t~/Pictures"), .add("~/Pictures"))
    }

    func testAddTakesAServerAddress() throws {
        let server = try XCTUnwrap(ServerLocation("smb://nas.local/Media"))
        XCTAssertEqual(parse("/add smb://nas.local/Media"), .connect(server))
        XCTAssertEqual(parse("/add  SMB://NAS.local/Media/ "), .connect(server))
        XCTAssertEqual(parse("/add cifs://nas.local/Media"), .connect(server))
        // An address macOS isn't handed is only text to add, which the scope rules then refuse.
        XCTAssertEqual(parse("/add https://example.com/share"), .add("https://example.com/share"))
        XCTAssertEqual(parse("/add smb://user:pass@nas.local/Media"), .add("smb://user:pass@nas.local/Media"))
    }

    func testClearTakesNothing() {
        XCTAssertEqual(parse("/clear"), .clear)
        XCTAssertEqual(parse(" /clear \n"), .clear)
        XCTAssertEqual(parse("/Clear"), .clear)
        // Words after it mean something else was meant, and a thread isn't dropped on a guess.
        XCTAssertEqual(parse("/clear everything"), .unknownCommand)
    }

    func testAnUnknownCommand() {
        for text in ["/help", "/model", "/model gpt-6-astra", "/scope", "/addfolder ~/x", "/clearall", "/", "/ add", "/?"] {
            XCTAssertEqual(parse(text), .unknownCommand, text)
        }
    }

    // MARK: A path or an address alone

    func testAPathAloneAddsAFolder() {
        for text in ["~/Documents/Tax 2026", "~/Pictures", "~", "~/", "/Volumes/Backup/Photos", "/Volumes/My Disk/Photos 2026",
                     "/home/helm/Documents/", "file:///home/helm/Documents", "FILE:///home/helm/My%20Files"] {
            XCTAssertEqual(parse(text), .add(text), text)
            XCTAssertEqual(parse("  " + text + "\n"), .add(text), text)
        }
    }

    func testAServerAddressAloneAsksToConnect() throws {
        XCTAssertEqual(parse("smb://nas.local/Media/Films"), .connect(try XCTUnwrap(ServerLocation("smb://nas.local/Media/Films"))))
        XCTAssertEqual(parse("afp://timecapsule/Data"), .connect(try XCTUnwrap(ServerLocation("afp://timecapsule/Data"))))
        XCTAssertEqual(parse(" nfs://192.168.1.20/volume1 "), .connect(try XCTUnwrap(ServerLocation("nfs://192.168.1.20/volume1"))))
        guard case .connect(let location) = parse("cifs://nas/share") else { return XCTFail("not a server") }
        XCTAssertEqual(location.scheme, "smb")
        // A web address and a server address with a password are ordinary words.
        XCTAssertEqual(parse("https://example.com/files"), .message("https://example.com/files", folderCandidates: []))
        XCTAssertEqual(parse("ftp://host/share"), .message("ftp://host/share", folderCandidates: []))
        XCTAssertEqual(parse("smb://me:secret@nas/share"), .message("smb://me:secret@nas/share", folderCandidates: []))
        // One inside a sentence is never acted on.
        XCTAssertEqual(parse("connect to smb://nas.local/Media please"),
                       .message("connect to smb://nas.local/Media please", folderCandidates: []))
    }

    // MARK: Messages

    func testAMessageWithNoPath() {
        XCTAssertEqual(parse("organize my downloads"), .message("organize my downloads", folderCandidates: []))
        XCTAssertEqual(parse("  Organize these\nby year  "), .message("Organize these\nby year", folderCandidates: []))
        // A slash inside a word, a fraction and a slash standing alone start no path.
        XCTAssertEqual(parse("sort by size and/or kind"), .message("sort by size and/or kind", folderCandidates: []))
        XCTAssertEqual(parse("keep 1/2 of them"), .message("keep 1/2 of them", folderCandidates: []))
        XCTAssertEqual(parse("photos / videos into one folder"), .message("photos / videos into one folder", folderCandidates: []))
        XCTAssertEqual(parse("about ~ 20 files"), .message("about ~ 20 files", folderCandidates: []))
    }

    func testAMessageThatEndsInAPath() {
        XCTAssertEqual(parse("Move everything in this folder to ~/Pictures/2026"),
                       .message("Move everything in this folder to ~/Pictures/2026",
                                folderCandidates: [AgentTrailingPath(path: "~/Pictures/2026", prefix: "Move everything in this folder to ")]))
        // A path can hold spaces, so it runs to the end of the message.
        XCTAssertEqual(parse("Copy the 12 selected items to /Volumes/Backup/My Trip 2026"),
                       .message("Copy the 12 selected items to /Volumes/Backup/My Trip 2026",
                                folderCandidates: [AgentTrailingPath(path: "/Volumes/Backup/My Trip 2026", prefix: "Copy the 12 selected items to ")]))
        XCTAssertEqual(parse("put these in file:///home/helm/Archive"),
                       .message("put these in file:///home/helm/Archive",
                                folderCandidates: [AgentTrailingPath(path: "file:///home/helm/Archive", prefix: "put these in ")]))
        XCTAssertEqual(parse("move it to ~/"), .message("move it to ~/", folderCandidates: [AgentTrailingPath(path: "~/", prefix: "move it to ")]))
    }

    func testCandidatesComeLeftmostFirst() {
        let text = "Copy /Volumes/A/One and ~/Two Three to file:///home/helm/Four"
        guard case .message(let message, let candidates) = parse(text) else { return XCTFail("not a message") }
        XCTAssertEqual(message, text)
        XCTAssertEqual(candidates, [
            AgentTrailingPath(path: "/Volumes/A/One and ~/Two Three to file:///home/helm/Four", prefix: "Copy "),
            AgentTrailingPath(path: "~/Two Three to file:///home/helm/Four", prefix: "Copy /Volumes/A/One and "),
            AgentTrailingPath(path: "file:///home/helm/Four", prefix: "Copy /Volumes/A/One and ~/Two Three to ")
        ])
        // Each candidate and what comes before it are the whole message, so the path can be swapped for an id.
        for candidate in candidates {
            XCTAssertEqual(candidate.prefix + candidate.path, text)
        }
        XCTAssertEqual(candidates.map(\.path.count), candidates.map(\.path.count).sorted(by: >))
    }

    func testAPathAcrossLines() {
        guard case .message(_, let candidates) = parse("move these\nto ~/Pictures/New Folder") else { return XCTFail("not a message") }
        XCTAssertEqual(candidates, [AgentTrailingPath(path: "~/Pictures/New Folder", prefix: "move these\nto ")])
    }

    // MARK: A key in the wrong place

    func testAMessageShapedLikeAKeyIsNeverAMessage() {
        XCTAssertEqual(parse(keyShaped), .looksLikeKey)
        XCTAssertEqual(parse("  \(keyShaped)\n"), .looksLikeKey)
        XCTAssertEqual(parse("my key is \(keyShaped)"), .looksLikeKey)
        XCTAssertEqual(parse("\(keyShaped) is my key, use it"), .looksLikeKey)
        XCTAssertEqual(parse("/add \(keyShaped)"), .looksLikeKey)
        XCTAssertEqual(parse("move to ~/Keys and use \(keyShaped)"), .looksLikeKey)
        for prefix in ["xai-", "AIza", "gsk_"] {
            XCTAssertEqual(parse(prefix + String(repeating: "x", count: 30)), .looksLikeKey, prefix)
        }
    }

    func testAKeyBesidePunctuationIsStillAKey() {
        let google = "AIza" + String(repeating: "Qw7", count: 10)
        for text in ["\(keyShaped).", "\(keyShaped),", "(\(keyShaped))", "\"\(keyShaped)\"", "key=\(keyShaped)",
                     "my key: \(google)!", "use “\(keyShaped)” please", "[\(keyShaped)]?"] {
            XCTAssertEqual(parse(text), .looksLikeKey, text)
        }
    }

    func testOrdinaryWordsAreNotAKey() {
        XCTAssertEqual(parse("sk-short"), .message("sk-short", folderCandidates: []))
        XCTAssertEqual(parse("rename skiing-photos-from-the-alps-2026"),
                       .message("rename skiing-photos-from-the-alps-2026", folderCandidates: []))
        XCTAssertEqual(parse("open sk-my-notes-from-2026-final.txt"),
                       .message("open sk-my-notes-from-2026-final.txt", folderCandidates: []))
        XCTAssertEqual(parse("is sk-short. fine?"), .message("is sk-short. fine?", folderCandidates: []))
    }
}
