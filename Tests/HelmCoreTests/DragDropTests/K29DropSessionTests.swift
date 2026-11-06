// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class K29DropSessionTests: XCTestCase {
    private func source(_ path: String, volume: String = "v") -> DraggedItem {
        DraggedItem(url: URL(fileURLWithPath: path), volumeID: volume)
    }
    func testRepeatedTargetsAndModifiersReuseValidationAndMatchStatelessPlanner() {
        let sources = (0..<1000).map { source("/source/file\($0)") }
        let session = FileDropSession(sources: sources)
        for location in [Location.trash, .recent, .directory(URL(fileURLWithPath: "/target"))] {
            let target = DropDestination(location: location, volumeID: "v")
            for flags: DropModifiers in [[], .option, .command, .control] {
                XCTAssertEqual(session.proposal(destination: target, modifiers: flags),
                               DropPlanner.proposal(sources: sources, destination: target, modifiers: flags))
            }
        }
        XCTAssertEqual(session.validationCount, 1)
        XCTAssertEqual(session.proposal(destination: DropDestination(location: .trash)).sources, sources)
    }
    func testSourceChangesRevalidateIncludingMetadataAndOrder() {
        let target = DropDestination(location: .directory(URL(fileURLWithPath: "/target")), volumeID: "v")
        let sources = [source("/a"), source("/b")]
        var session = FileDropSession(sources: sources)
        session.replaceSources(sources)
        XCTAssertEqual(session.validationCount, 1)
        session.replaceSources([source("/a", volume: "different"), source("/b")])
        XCTAssertEqual(session.proposal(destination: target).operation, .copy)
        session.replaceSources(sources.reversed())
        XCTAssertEqual(session.proposal(destination: target).sources, sources.reversed())
        session.replaceSources([source("/a"), source("/a/child")])
        XCTAssertEqual(session.proposal(destination: target).rejection, .overlappingSources)
        XCTAssertEqual(session.validationCount, 4)
    }
    func testEndIsTerminalAndReleasesSourcePaths() {
        var session = FileDropSession(sources: [source("/a")])
        session.end(); session.end(); session.replaceSources([source("/new")])
        let result = session.proposal(destination: DropDestination(location: .trash))
        XCTAssertTrue(session.isEnded); XCTAssertTrue(result.sources.isEmpty)
        XCTAssertEqual(result.rejection, .emptySources)
        XCTAssertNotEqual(session.id, FileDropSession(sources: []).id)
    }
    func testCachedRejectionsAndTargetRestrictionsMatchStateless() {
        let invalid = DraggedItem(url: URL(fileURLWithPath: "/a"), id: ItemID(rawValue: "/wrong"))
        for sources in [[], [invalid], [source("/a"), source("/a")], [source("/a"), source("/ab")]] {
            let session = FileDropSession(sources: sources)
            for destination in [DropDestination(location: .recent),
                                DropDestination(location: .directory(URL(fileURLWithPath: "/target")), isWritable: false),
                                DropDestination(location: .trash)] {
                XCTAssertEqual(session.proposal(destination: destination, allowedOperations: []),
                               DropPlanner.proposal(sources: sources, destination: destination, allowedOperations: []))
            }
        }
    }
}
