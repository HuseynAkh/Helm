// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

/// F-050/B-066: plan validation retains originals and rejects an entire invalid selection.
final class T3InspectorTests: XCTestCase {
    private func item(_ path: String = "/a.txt", locked: Bool = false, directory: Bool = false) -> InspectorItem {
        InspectorItem(url: URL(fileURLWithPath: path), isDirectory: directory,
                      attributes: [.name("a.txt"), .permissions(0o6754), .comment("old"), .tags(["old"]),
                                   .locked(locked), .hidden(false), .hiddenExtension(false), .defaultApplication(nil)],
                      editableFields: Set(InspectorField.allCases))
    }
    private func rejects(_ draft: InspectorAttribute, _ expected: InspectorValidationError) {
        var model = InspectorEditModel(items: [item()])
        model.set(draft)
        XCTAssertThrowsError(try model.makePlan()) { XCTAssertEqual($0 as? InspectorValidationError, expected) }
        XCTAssertEqual(model.pending[draft.field], draft)
        XCTAssertEqual(model.originals, [item()])
    }
    func testNulComment() { rejects(.comment("a\0b"), .invalidComment) }
    func testDuplicateTags() { rejects(.tags(["a", "a"]), .invalidTag) }
    func testBlankTag() { rejects(.tags([" \t"]), .invalidTag) }
    func testNewlineTag() { rejects(.tags(["a\nb"]), .invalidTag) }
    func testInvalidModeHighBit() { rejects(.permissions(0x8000), .invalidPermissions) }
    func testInvalidModeAllBits() { rejects(.permissions(.max), .invalidPermissions) }
    func testNonApplicationURL() { rejects(.defaultApplication(URL(fileURLWithPath: "/tmp/tool.txt")), .invalidApplication) }
    func testExtensionRequiresConfirmation() { rejects(.name("a.pdf"), .extensionConfirmationRequired) }
    func testConfirmationDoesNotPersistAcrossDrafts() throws {
        var model = InspectorEditModel(items: [item()])
        model.set(.name("a.pdf"))
        XCTAssertEqual(try model.makePlan(confirmExtensionChange: true).items.first?.item.url.path, "/a.txt")
        model.set(.name("a.jpg"))
        XCTAssertThrowsError(try model.makePlan()) { XCTAssertEqual($0 as? InspectorValidationError, .extensionConfirmationRequired) }
    }
    func testUnlockPrecedesEditsAndKeepsOriginalIdentity() throws {
        var model = InspectorEditModel(items: [item(locked: true)])
        model.set(.name("b.txt")); model.set(.comment("new")); model.set(.locked(false))
        let plan = try model.makePlan()
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items.first?.item.id, ItemID(url: URL(fileURLWithPath: "/a.txt")))
        XCTAssertEqual(plan.items.first?.changes.map(\.proposed), [.locked(false), .comment("new"), .name("b.txt")])
        XCTAssertEqual(plan, try model.makePlan())
    }
    func testRelockIsLast() throws {
        var model = InspectorEditModel(items: [item()])
        model.set(.locked(true)); model.set(.hidden(true)); model.set(.name("b.txt"))
        XCTAssertEqual(try model.makePlan().items.first?.changes.map(\.proposed), [.hidden(true), .name("b.txt"), .locked(true)])
    }
    func testLockedSelectionRejectsAllItems() {
        var model = InspectorEditModel(items: [item(), item("/b.txt", locked: true)])
        model.set(.comment("new"))
        XCTAssertThrowsError(try model.makePlan()) { XCTAssertEqual($0 as? InspectorValidationError, .locked(ItemID(url: URL(fileURLWithPath: "/b.txt")))) }
    }
    func testUnknownPermissionsInEitherOrder() {
        let unknown = InspectorItem(url: URL(fileURLWithPath: "/unknown"), attributes: [], editableFields: [.permissions])
        for items in [[item(), unknown], [unknown, item()]] {
            var model = InspectorEditModel(items: items)
            XCTAssertFalse(model.canEdit(.permissions))
            XCTAssertEqual(model.value(for: .permissions), .unavailable)
            for subject in PermissionSubject.allCases { XCTAssertEqual(model.permissions.row(subject), .unavailable) }
            model.permissions.set(PermissionAccess(bits: 7), for: .everyone)
            XCTAssertThrowsError(try model.makePlan()) { XCTAssertEqual($0 as? InspectorValidationError, .unsupported(unknown.id, .permissions)) }
        }
    }
    func testScaleSelectionPreservesOrderAndOriginals() throws {
        let items = (0..<4096).map { item("/file\($0)") }
        var model = InspectorEditModel(items: items + items.reversed())
        model.set(.comment("共同 تعليق"))
        let plan = try model.makePlan()
        XCTAssertEqual(plan.items.map(\.item), items)
        XCTAssertTrue(plan.items.allSatisfy { $0.changes == [InspectorAttributeChange(original: .comment("old"), proposed: .comment("共同 تعليق"))] })
        model.reset(); XCTAssertTrue(try model.makePlan().isEmpty)
    }
    func testRecursiveMixedSelectionRejected() {
        var model = InspectorEditModel(items: [item(directory: true), item("/file")])
        model.applyPermissionsToEnclosedItems = true
        XCTAssertThrowsError(try model.makePlan()) { XCTAssertEqual($0 as? InspectorValidationError, .recursivePermissionsRequireDirectory) }
    }
}
