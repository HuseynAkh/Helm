// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class DropPlannerTests: XCTestCase {
    private func item(_ path: String = "/source/file", volume: String? = "A") -> DraggedItem {
        DraggedItem(url: URL(fileURLWithPath: path), volumeID: volume)
    }
    private func destination(_ path: String = "/target", volume: String? = "A") -> DropDestination {
        DropDestination(location: .directory(URL(fileURLWithPath: path)), volumeID: volume)
    }
    func testAllModifierCombinationsAndFeedback() {
        let expected: [FileDropOperation] = [.move, .copy, .move, .alias, .alias, .alias, .alias, .alias]
        for raw in 0..<8 {
            let proposal = DropPlanner.proposal(sources: [item()], destination: destination(), modifiers: DropModifiers(rawValue: raw), allowedOperations: [.copy, .move, .alias, .moveToTrash])
            XCTAssertEqual(proposal.operation, expected[raw])
            XCTAssertNil(proposal.rejection)
            XCTAssertEqual(proposal.feedback.rawValue, expected[raw].rawValue)
            XCTAssertEqual(proposal.highlight, .background)
        }
    }
    func testVolumeDefaults() {
        for volume: String? in ["B", nil, ""] {
            XCTAssertEqual(DropPlanner.proposal(sources: [item(volume: volume)], destination: destination()).operation, .copy)
        }
        XCTAssertEqual(DropPlanner.proposal(sources: [item()], destination: destination(volume: nil)).operation, .copy)
        XCTAssertEqual(DropPlanner.proposal(sources: [item(), item("/other", volume: "B")], destination: destination()).operation, .copy)
        XCTAssertEqual(DropPlanner.proposal(sources: [item(volume: "B")], destination: destination(), modifiers: .command).operation, .move)
    }
    func testSourceMaskDoesNotSilentlyChangeForcedOperation() {
        for operation in [FileDropOperation.copy, .move, .alias, .moveToTrash] {
            let modifiers: DropModifiers = operation == .copy ? .option : operation == .alias ? .control : .command
            let target = operation == .moveToTrash ? DropDestination(location: .trash) : destination()
            let result = DropPlanner.proposal(sources: [item()], destination: target, modifiers: modifiers, allowedOperations: [])
            XCTAssertEqual(result.rejection, .unsupportedOperation)
            XCTAssertEqual(result.feedback, .forbidden)
            XCTAssertEqual(result.highlight, .none)
        }
    }
    func testPathGuardsAndComponentBoundaries() {
        let cases: [(String, String, DropRejection?)] = [
            ("/a", "/a", .intoItself), ("/a", "/a/b", .intoDescendant),
            ("/", "/a", .intoDescendant), ("/a/b", "/a", .sameParentNoOp),
            ("/a", "/ab", nil), ("/a/b/../c", "/a/c/d", .intoDescendant)
        ]
        for (source, target, reason) in cases {
            XCTAssertEqual(DropPlanner.proposal(sources: [item(source)], destination: destination(target)).rejection, reason)
        }
        for modifiers: DropModifiers in [.option, .control, [.option, .command]] {
            XCTAssertNotNil(DropPlanner.proposal(sources: [item("/a/b")], destination: destination("/a"), modifiers: modifiers, allowedOperations: [.copy, .move, .alias]).operation)
        }
        XCTAssertEqual(DropPlanner.proposal(sources: [item("/a/b"), item("/elsewhere")], destination: destination("/a")).rejection, .sameParentNoOp)
    }
    func testMissingVolumeStillRejectsSameParentDefault() {
        XCTAssertEqual(DropPlanner.proposal(sources: [item("/a/b", volume: nil)], destination: destination("/a", volume: nil)).rejection, .sameParentNoOp)
        XCTAssertEqual(DropPlanner.proposal(sources: [item("/a/b", volume: nil)], destination: destination("/a", volume: nil), modifiers: .option).operation, .copy)
    }
    func testInvalidAndOverlappingSources() throws {
        XCTAssertEqual(DropPlanner.proposal(sources: [], destination: destination()).rejection, .emptySources)
        let web = try XCTUnwrap(URL(string: "https://example.invalid/file"))
        XCTAssertEqual(DropPlanner.proposal(sources: [DraggedItem(url: web)], destination: destination()).rejection, .invalidFileURL)
        let mismatched = DraggedItem(url: item().url, id: ItemID(rawValue: "/wrong"))
        XCTAssertEqual(DropPlanner.proposal(sources: [mismatched], destination: destination()).rejection, .identityMismatch)
        for sources in [[item(), item()], [item("/a"), item("/a/b")], [item("/a/b"), item("/a")]] {
            XCTAssertEqual(DropPlanner.proposal(sources: sources, destination: destination()).rejection, .overlappingSources)
        }
        XCTAssertEqual(DropPlanner.proposal(sources: [item()], destination: DropDestination(location: .directory(web))).rejection, .invalidFileURL)
    }
    func testDestinationPolicies() {
        let cases: [(DropDestination, DropRejection)] = [
            (DropDestination(location: .recent), .virtualDestination),
            (DropDestination(location: .directory(item().url), isSearchResults: true), .virtualDestination),
            (DropDestination(location: .trash, isWritable: false), .readOnlyDestination),
            (DropDestination(location: .directory(item().url), isDirectory: false), .notDirectory),
            (DropDestination(location: .directory(item().url), isPackage: true), .packageContentsDisallowed)
        ]
        for (target, reason) in cases {
            XCTAssertEqual(DropPlanner.proposal(sources: [item()], destination: target).rejection, reason)
        }
        let id = ItemID(rawValue: "/package")
        let package = DropDestination(location: .directory(id.url), isPackage: true, allowsPackageContents: true, highlight: .row(id))
        XCTAssertEqual(DropPlanner.proposal(sources: [item()], destination: package).highlight, .row(id))
        let trash = DropPlanner.proposal(sources: [item()], destination: DropDestination(location: .trash), modifiers: .option)
        XCTAssertEqual(trash.operation, .moveToTrash)
        XCTAssertEqual(trash.feedback, .trash)
    }
    func testEntryConversionAndProposalRetention() {
        let entry = FileEntry(url: item().url, volumeIdentifier: "A")
        XCTAssertEqual(DraggedItem(entry: entry), item())
        let proposal = DropPlanner.proposal(sources: [item()], destination: destination())
        XCTAssertEqual(proposal.sources, [item()])
        XCTAssertEqual(proposal.destination, destination())
        XCTAssertEqual(DropModifiers.option.union(.command).rawValue, 3)
    }
}
