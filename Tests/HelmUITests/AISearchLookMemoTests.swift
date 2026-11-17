#if os(macOS)
import Foundation
import XCTest
import HelmCore
@testable import HelmUI

/// What AI search's memo keeps of the pictures Read contents made, and which files a query lets the model look at.
final class AISearchLookMemoTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_000)

    private func pictured(_ bytes: Int, kind: AgentContentKind = .image) -> AgentContentSummary {
        AgentContentSummary(kind: kind, status: .read, labels: [AgentContentLabel(identifier: "sky", confidence: 0.9)],
                            images: [AgentContentImage(jpeg: Data(count: bytes), width: 512, height: 512, source: .picture)])
    }

    func testASummaryWithPicturesIsAnsweredForPicturesOnlyWhenItWasReadWithThem() {
        let memo = AgentContentMemo()
        memo.keep(AgentContentSummary(kind: .image, status: .read), path: "/a.png", modified: day)
        XCTAssertNotNil(memo.summary(path: "/a.png", modified: day))
        XCTAssertNil(memo.summary(path: "/a.png", modified: day, withPictures: true), "read without pictures: read again for them")
        memo.keep(pictured(1_000), path: "/a.png", modified: day, withPictures: true)
        XCTAssertEqual(memo.summary(path: "/a.png", modified: day, withPictures: true)?.images.count, 1)
        XCTAssertEqual(memo.heldPictureBytes, 1_000)
        // A summary read without pictures doesn't take the place of one read with them.
        memo.keep(AgentContentSummary(kind: .image, status: .read), path: "/a.png", modified: day)
        XCTAssertEqual(memo.summary(path: "/a.png", modified: day)?.images.count, 1)
        // A text PDF read with pictures asked for has none, and is still answered.
        memo.keep(AgentContentSummary(kind: .pdf, status: .read, lines: ["Invoice"]), path: "/b.pdf", modified: day, withPictures: true)
        XCTAssertEqual(memo.summary(path: "/b.pdf", modified: day, withPictures: true)?.lines, ["Invoice"])
        memo.clear()
        XCTAssertEqual(memo.heldPictureBytes, 0)
        XCTAssertEqual(memo.count, 0)
    }

    func testPastTheCapASummaryIsKeptWithoutItsPictures() {
        let memo = AgentContentMemo()
        let third = AgentContentMemo.pictureBytes / 3 + 1
        memo.keep(pictured(third), path: "/1.png", modified: day, withPictures: true)
        memo.keep(pictured(third), path: "/2.png", modified: day, withPictures: true)
        XCTAssertEqual(memo.heldPictureBytes, 2 * third)
        memo.keep(pictured(third), path: "/3.png", modified: day, withPictures: true)
        XCTAssertEqual(memo.heldPictureBytes, 2 * third, "the third would pass the cap")
        let kept = memo.summary(path: "/3.png", modified: day)
        XCTAssertEqual(kept?.images, [], "kept without its pictures")
        XCTAssertEqual(kept?.labels.map(\.identifier), ["sky"], "and with its words")
        XCTAssertNil(memo.summary(path: "/3.png", modified: day, withPictures: true), "so it is read again for pictures")
        // A file read again takes its old pictures' room back first.
        memo.keep(pictured(third), path: "/2.png", modified: day, withPictures: true)
        XCTAssertEqual(memo.heldPictureBytes, 2 * third)
        memo.keep(pictured(10), path: "/2.png", modified: day, withPictures: true)
        XCTAssertEqual(memo.heldPictureBytes, third + 10)
        memo.keep(pictured(third), path: "/3.png", modified: day, withPictures: true)
        XCTAssertEqual(memo.summary(path: "/3.png", modified: day, withPictures: true)?.images.count, 1, "room again")
        XCTAssertEqual(memo.heldPictureBytes, 2 * third + 10)
        XCTAssertLessThanOrEqual(memo.heldPictureBytes, AgentContentMemo.pictureBytes)
        XCTAssertEqual(AgentContentMemo.pictureBytes, 24 * 1024 * 1024)
    }
}

/// Which files a query that looks for words inside files lets the model look at: the same query with no words for
/// inside files, kept to what Read contents reads, documents too unless the query is kept to pictures or videos.
@MainActor final class AISearchLookQueryTests: XCTestCase {
    func testAQueryAsOneForTheFilesTheModelLooksAt() {
        XCTAssertNil(AISearchRunner.lookQuery(AISearchQuery(nameAny: ["beach"])), "no words for inside files")
        let any = AISearchRunner.lookQuery(AISearchQuery(nameAny: ["trip"], contentAll: ["dog"]))
        XCTAssertEqual(any?.contentAll, [])
        XCTAssertEqual(any?.kinds, [.image, .video, .pdf, .text, .code, .document])
        XCTAssertEqual(any?.nameAny, ["trip"])
        XCTAssertEqual(AISearchRunner.lookQuery(AISearchQuery(contentAll: ["dog"], kinds: [.image]))?.kinds, [.image])
        XCTAssertEqual(AISearchRunner.lookQuery(AISearchQuery(contentAll: ["invoice"], kinds: [.document]))?.kinds,
                       [.pdf, .text, .document], "a document is a PDF, text or a Word file")
        XCTAssertEqual(AISearchRunner.lookQuery(AISearchQuery(contentAll: ["invoice"], kinds: [.pdf]))?.kinds, [.pdf])
        XCTAssertNil(AISearchRunner.lookQuery(AISearchQuery(contentAll: ["song"], kinds: [.audio])))
        XCTAssertEqual(AISearchRunner.lookQuery(AISearchQuery(contentAll: ["dog"], extensions: ["jpg", "docx", "zip"]))?.extensions,
                       ["jpg", "docx"])
        XCTAssertNil(AISearchRunner.lookQuery(AISearchQuery(contentAll: ["dog"], extensions: ["xlsx"])))
    }

    func testOnlyWhatReadContentsReadsIsLookedAt() {
        func entry(_ name: String, _ kind: FileEntryKind = .regular) -> FileEntry {
            FileEntry(url: URL(fileURLWithPath: "/home/someone/" + name), kind: kind)
        }
        for name in ["a.jpg", "b.mov", "c.pdf", "d.txt", "e.docx", "f.swift", "g.rtf"] {
            XCTAssertTrue(AISearchRunner.isReadable(entry(name)), name)
        }
        for name in ["h.zip", "i.xlsx", "j.mp3", "k.pages"] {
            XCTAssertFalse(AISearchRunner.isReadable(entry(name)), name)
        }
        XCTAssertFalse(AISearchRunner.isReadable(entry("Photos.jpg", .directory)), "a folder")
        XCTAssertFalse(AISearchRunner.isReadable(entry("link.png", .symlinkToFile)), "a link")
    }
}
#endif
