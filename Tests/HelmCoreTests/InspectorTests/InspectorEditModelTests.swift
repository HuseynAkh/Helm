// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class InspectorEditModelTests: XCTestCase {
    private func item(_ path: String = "/a.txt", locked: Bool = false, mode: UInt16 = 0o644,
                      directory: Bool = false, editable: Set<InspectorField> = Set(InspectorField.allCases)) -> InspectorItem {
        InspectorItem(url: URL(fileURLWithPath: path), isDirectory: directory,
                      attributes: [.name(URL(fileURLWithPath: path).lastPathComponent), .locked(locked),
                                   .hidden(false), .hiddenExtension(false), .tags([]), .comment(""),
                                   .defaultApplication(nil), .permissions(mode)], editableFields: editable)
    }
    private func assertError(_ model: InspectorEditModel, _ error: InspectorValidationError,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try model.makePlan(), file: file, line: line) {
            XCTAssertEqual($0 as? InspectorValidationError, error, file: file, line: line)
        }
    }
    func testOriginalMixedUnavailableAndDuplicateSelection() throws {
        let first = item()
        var model = InspectorEditModel(items: [first, first, item("/b.txt")])
        XCTAssertEqual(model.originals.count, 2)
        XCTAssertEqual(model.value(for: .name), .mixed)
        XCTAssertEqual(model.value(for: .locked), .value(.locked(false)))
        XCTAssertFalse(model.canEdit(.name))
        XCTAssertTrue(model.canEdit(.comment))
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(try model.makePlan().isEmpty)
        model.set(.comment("draft"))
        XCTAssertEqual(model.value(for: .comment), .value(.comment("draft")))
        XCTAssertEqual(model.originals[0], first)
        XCTAssertEqual(try model.makePlan().items.count, 2)
        XCTAssertTrue(model.isDirty)
        model.reset(.comment)
        XCTAssertFalse(model.isDirty)
        let missing = InspectorItem(url: URL(fileURLWithPath: "/missing"), attributes: [])
        let unknown = InspectorEditModel(items: [first, missing])
        XCTAssertEqual(unknown.value(for: .comment), .unavailable)
        XCTAssertFalse(unknown.canEdit(.comment))
    }
    func testEveryAttributePlanIncludesOriginalAndRevertClearsDirty() throws {
        let changes: [InspectorAttribute] = [.name("b.txt"), .locked(true), .hidden(true), .hiddenExtension(true),
            .tags(["Red", "Work"]), .comment("line1\nline2"),
            .defaultApplication(URL(fileURLWithPath: "/Applications/Editor.app")), .permissions(0o755)]
        for change in changes {
            let original = item()
            var model = InspectorEditModel(items: [original])
            model.set(change)
            XCTAssertTrue(model.isDirty)
            let plan = try model.makePlan()
            XCTAssertEqual(plan.items.count, 1)
            XCTAssertEqual(plan.items[0].changes.count, 1)
            XCTAssertEqual(plan.items[0].changes[0].proposed, change)
            XCTAssertEqual(plan.items[0].changes[0].original, original.attributes[change.field])
            if let previous = original.attributes[change.field] { model.set(previous) }
            XCTAssertFalse(model.isDirty)
        }
    }
    func testInvalidNamesAndExtensionConfirmation() throws {
        for name in ["", " ", ".", "..", "a/b", "bad\0name", String(repeating: "é", count: 128)] {
            var model = InspectorEditModel(items: [item()]); model.set(.name(name))
            assertError(model, .invalidName)
        }
        var model = InspectorEditModel(items: [item()])
        model.set(.name(" a.txt "))
        XCTAssertFalse(model.isDirty)
        model.set(.name("b.png"))
        assertError(model, .extensionConfirmationRequired)
        XCTAssertEqual(try model.makePlan(confirmExtensionChange: true).items.count, 1)
        model.set(.name("b"))
        assertError(model, .extensionConfirmationRequired)
        model = InspectorEditModel(items: [item("/dir.old", directory: true)])
        model.set(.name("dir.new"))
        XCTAssertEqual(try model.makePlan().items.count, 1)
        model = InspectorEditModel(items: [item(), item("/b.txt")])
        model.set(.name("c.txt"))
        assertError(model, .multipleItemRename)
    }
    func testAttributeValidation() throws {
        let invalid: [(InspectorAttribute, InspectorValidationError)] = [
            (.tags([""]), .invalidTag), (.tags([" \n"]), .invalidTag), (.tags(["a\0"]), .invalidTag),
            (.tags(["a\nb"]), .invalidTag), (.tags(["a", "a"]), .invalidTag),
            (.comment("bad\0"), .invalidComment),
            (.defaultApplication(URL(string: "https://example.com/App.app")), .invalidApplication),
            (.defaultApplication(URL(fileURLWithPath: "/tmp/file")), .invalidApplication),
            (.permissions(0o10000), .invalidPermissions)]
        for (value, error) in invalid {
            var model = InspectorEditModel(items: [item()]); model.set(value); assertError(model, error)
        }
        var model = InspectorEditModel(items: [item()])
        model.set(.name(".hidden:colon.txt"))
        XCTAssertFalse(try model.makePlan().isEmpty)
        model.reset(); XCTAssertFalse(model.isDirty)
    }
    func testUnsupportedAndEmptySelectionsNeverProducePartialPlan() {
        var empty = InspectorEditModel(items: [])
        XCTAssertFalse(empty.canEdit(.comment))
        XCTAssertEqual(empty.value(for: .comment), .unavailable)
        empty.set(.comment("x")); assertError(empty, .noSelection)
        let blocked = item("/b.txt", editable: [])
        var model = InspectorEditModel(items: [item(), blocked])
        model.set(.comment("x")); assertError(model, .unsupported(blocked.id, .comment))
        let missing = InspectorItem(url: URL(fileURLWithPath: "/c"), attributes: [], editableFields: [.comment])
        model = InspectorEditModel(items: [missing]); model.set(.comment("x"))
        assertError(model, .unsupported(missing.id, .comment))
    }
    func testUnlockBeforeEditsAndLockAfterRename() throws {
        let locked = item(locked: true)
        var model = InspectorEditModel(items: [locked]); model.set(.name("b.txt"))
        assertError(model, .locked(locked.id))
        model.set(.locked(false))
        XCTAssertEqual(try model.makePlan().items[0].changes.map(\.proposed), [.locked(false), .name("b.txt")])
        model = InspectorEditModel(items: [item()]); model.set(.locked(true)); model.set(.name("b.txt"))
        XCTAssertEqual(try model.makePlan().items[0].changes.map(\.proposed), [.name("b.txt"), .locked(true)])
    }
    func testPerRowMultiSelectionAndRecursivePermissionPlans() throws {
        var model = InspectorEditModel(items: [item(mode: 0o4644, directory: true), item("/b", mode: 0o2750, directory: true)])
        model.permissions.set(PermissionAccess(bits: 7), for: .owner)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.value(for: .permissions), .mixed)
        let plan = try model.makePlan()
        XCTAssertEqual(plan.items.map { $0.changes[0].proposed }, [.permissions(0o4744)])
        model.applyPermissionsToEnclosedItems = true
        XCTAssertEqual(try model.makePlan().items.count, 2)
        XCTAssertTrue(try model.makePlan().items.allSatisfy { $0.changes[0].applyToEnclosedItems })
        model.reset(.permissions); XCTAssertFalse(model.isDirty)
        model.applyPermissionsToEnclosedItems = true
        XCTAssertEqual(try model.makePlan().items.count, 2)
        model = InspectorEditModel(items: [item()]); model.applyPermissionsToEnclosedItems = true
        assertError(model, .recursivePermissionsRequireDirectory)
        let missing = InspectorItem(url: URL(fileURLWithPath: "/d"), isDirectory: true, attributes: [])
        model = InspectorEditModel(items: [missing]); model.applyPermissionsToEnclosedItems = true
        assertError(model, .unsupported(missing.id, .permissions))
    }
    func testPermissionDraftOverridesRowsAndCanReset() throws {
        var model = InspectorEditModel(items: [item()])
        model.permissions.set(PermissionAccess(bits: 7), for: .owner)
        XCTAssertEqual(model.value(for: .permissions), .value(.permissions(0o744)))
        model.set(.permissions(0o600))
        XCTAssertEqual(try model.makePlan().items[0].changes[0].proposed, .permissions(0o600))
        model.reset(.permissions)
        XCTAssertEqual(model.value(for: .permissions), .value(.permissions(0o644)))
        XCTAssertFalse(model.isDirty)
    }
    func testWholeModeRevertClearsOlderRowsAndPreservesRecursiveIntent() throws {
        for recursive in [false, true] {
            var model = InspectorEditModel(items: [item(directory: true)])
            model.permissions.set(PermissionAccess(bits: 7), for: .owner)
            model.applyPermissionsToEnclosedItems = recursive
            model.set(.permissions(0o600))
            XCTAssertEqual(model.permissions.row(.owner), .value(PermissionAccess(bits: 6)))
            XCTAssertEqual(model.permissions.row(.group), .value(PermissionAccess(bits: 0)))
            model.set(.permissions(0o644))
            XCTAssertEqual(model.value(for: .permissions), .value(.permissions(0o644)))
            XCTAssertEqual(model.permissions.row(.owner), .value(PermissionAccess(bits: 6)))
            XCTAssertEqual(model.permissions.row(.group), .value(PermissionAccess(bits: 4)))
            XCTAssertEqual(model.isDirty, recursive)
            XCTAssertEqual(try model.makePlan().isEmpty, !recursive)
            XCTAssertEqual(model.applyPermissionsToEnclosedItems, recursive)
        }
    }
    func testRowEditModifiesWholeModeAndResetClearsIt() throws {
        var model = InspectorEditModel(items: [item(mode: 0o4644)])
        model.set(.permissions(0o4600))
        model.permissions.set(PermissionAccess(bits: 4), for: .group)
        XCTAssertEqual(model.value(for: .permissions), .value(.permissions(0o4640)))
        XCTAssertEqual(model.permissions.row(.group), .value(PermissionAccess(bits: 4)))
        XCTAssertEqual(try model.makePlan().items[0].changes[0].proposed, .permissions(0o4640))
        model.permissions.reset()
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(try model.makePlan().isEmpty)
    }
    func testUnknownPermissionsRemainUnavailableInEitherSelectionOrder() {
        let known = item(directory: true)
        let unknown = InspectorItem(url: URL(fileURLWithPath: "/unknown"), isDirectory: true,
                                    attributes: [], editableFields: [.permissions])
        for items in [[known, unknown], [unknown, known]] {
            var model = InspectorEditModel(items: items)
            XCTAssertEqual(model.value(for: .permissions), .unavailable)
            XCTAssertFalse(model.canEdit(.permissions))
            for subject in PermissionSubject.allCases {
                XCTAssertEqual(model.permissions.row(subject), .unavailable)
            }
            model.permissions.set(PermissionAccess(bits: 7), for: .owner)
            XCTAssertEqual(model.permissions.row(.owner), .unavailable)
            assertError(model, .unsupported(unknown.id, .permissions))
            model.reset()
            model.applyPermissionsToEnclosedItems = true
            assertError(model, .unsupported(unknown.id, .permissions))
            model.set(.permissions(0o600))
            XCTAssertEqual(model.permissions.row(.owner), .value(PermissionAccess(bits: 6)))
            assertError(model, .unsupported(unknown.id, .permissions))
        }
        let mixed = InspectorEditModel(items: [known, item("/other", mode: 0o744)])
        XCTAssertEqual(mixed.permissions.row(.owner), .mixed)
    }
    func testClearingExistingValuesIsAnExplicitChange() throws {
        let original = InspectorItem(url: URL(fileURLWithPath: "/a"), attributes: [.tags(["Work"]), .comment("text"),
            .defaultApplication(URL(fileURLWithPath: "/A.app"))], editableFields: [.tags, .comment, .defaultApplication])
        var model = InspectorEditModel(items: [original])
        model.set(.tags([])); model.set(.comment("")); model.set(.defaultApplication(nil))
        XCTAssertEqual(try model.makePlan().items[0].changes.count, 3)
    }
}
