import Foundation
import XCTest
import HelmCore
import HelmUI

/// Who can change what in Properties: the person's own file, folder, package or alias gets Finder's pop-ups, and a
/// file Nautilus's execute checkbox. Another account's, root's and a link's are shown as macOS keeps them, and say why.
final class PropertiesPermissionsTests: XCTestCase {
    private let identity = FileObjectIdentity(scope: "native:1", object: "7")
    private let file = FileEntry(url: URL(fileURLWithPath: "/home/pat/notes.txt"), size: 5)
    private let folder = FileEntry(url: URL(fileURLWithPath: "/home/pat/Shared"), kind: .directory, size: 4096)

    private func yours(_ mode: UInt16, refusal: PermissionRefusal? = nil) -> PropertiesSupplement {
        PropertiesSupplement(posixMode: mode, group: "staff", ownerIsYou: true, locked: refusal == .locked,
                             permissionTarget: PermissionTarget(mode: mode, identity: identity, refusal: refusal))
    }
    private func theirs(_ mode: UInt16, owner: String) -> PropertiesSupplement {
        PropertiesSupplement(posixMode: mode, owner: owner, group: "staff", ownerIsYou: false, locked: false,
                             permissionTarget: PermissionTarget(mode: mode, identity: identity, refusal: .notOwner))
    }
    private func rows(_ model: PropertiesViewModel) -> [String: PropertiesRow] {
        Dictionary(uniqueKeysWithValues: model.permissionRows.map { ($0.label, $0) })
    }

    func testYourFileHasFindersPopUpsAndTheExecuteCheckbox() {
        let model = PropertiesViewModel(entries: [file], supplement: yours(0o644))
        let rows = rows(model)
        XCTAssertTrue(model.showsPermissionControls)
        XCTAssertTrue(model.permissionControlsEnabled)
        XCTAssertEqual(model.permissionRows.map(\.label), ["Owner", "Group", "Others", "Locked"])
        XCTAssertEqual(rows["Owner"]?.value, "You")
        XCTAssertEqual(rows["Owner"]?.control, PermissionControl(subject: .owner, choice: .readWrite))
        XCTAssertEqual(rows["Group"]?.value, "staff")
        XCTAssertEqual(rows["Group"]?.control?.title, "Read only")
        XCTAssertEqual(rows["Others"]?.value, "")
        XCTAssertEqual(rows["Others"]?.note, "Can only read")
        XCTAssertEqual(rows["Others"]?.control?.subject, .everyone)
        XCTAssertNil(rows["Runs as Program"], "the checkbox stands in for it")
        XCTAssertEqual(model.allowsExecuting, false)
        XCTAssertTrue(model.canToggleExecuting)
        XCTAssertNil(model.permissionsFooter)
        XCTAssertEqual(model.mode(choosing: .noAccess, for: .group), 0o604)
        XCTAssertEqual(model.mode(choosing: .readWrite, for: .everyone), 0o646)
        XCTAssertEqual(model.mode(allowingExecution: true), 0o755)
    }

    /// A folder, and an app or other package, which is a folder on disk, choose with execute and have no checkbox.
    func testYourFolderAndPackageChooseWithExecuteAndHaveNoCheckbox() {
        let model = PropertiesViewModel(entries: [folder], supplement: yours(0o755))
        XCTAssertEqual(rows(model)["Others"]?.control?.choice, .readOnly)
        XCTAssertNil(model.allowsExecuting)
        XCTAssertNil(model.mode(allowingExecution: true))
        XCTAssertEqual(model.mode(choosing: .noAccess, for: .everyone), 0o750)
        XCTAssertEqual(model.mode(choosing: .readWrite, for: .group), 0o775)
        let app = FileEntry(url: URL(fileURLWithPath: "/home/pat/Tool.app"), kind: .package, size: 7)
        let package = PropertiesViewModel(entries: [app], supplement: yours(0o755))
        XCTAssertTrue(package.showsPermissionControls)
        XCTAssertNil(package.allowsExecuting)
        XCTAssertEqual(package.mode(choosing: .noAccess, for: .everyone), 0o750)
        let alias = FileEntry(url: URL(fileURLWithPath: "/home/pat/notes alias"), kind: .alias, size: 900)
        let aliasModel = PropertiesViewModel(entries: [alias], supplement: yours(0o644))
        XCTAssertTrue(aliasModel.showsPermissionControls)
        XCTAssertNil(aliasModel.allowsExecuting)
    }

    /// Bits Finder has no choice for show as Custom, with Nautilus's words for them under the pop-up.
    func testBitsThatMatchNoChoiceAreCustom() {
        let odd = PropertiesViewModel(entries: [file], supplement: yours(0o624))
        XCTAssertEqual(rows(odd)["Group"]?.control, PermissionControl(subject: .group, choice: nil))
        XCTAssertEqual(rows(odd)["Group"]?.control?.title, "Custom")
        XCTAssertEqual(rows(odd)["Group"]?.note, "Can only write")
        let listOnly = PropertiesViewModel(entries: [folder], supplement: yours(0o745))
        XCTAssertEqual(rows(listOnly)["Group"]?.control?.title, "Custom")
        XCTAssertEqual(rows(listOnly)["Group"]?.note, "Can list files only")
        XCTAssertEqual(rows(listOnly)["Others"]?.control?.choice, .readOnly)
    }

    /// Another account's item and root's are shown as they are, as before, and say why they can't be changed here.
    func testAnotherAccountsOrRootsItemIsOnlyShown() {
        for owner in ["Another account (ID 502)", "root"] {
            let model = PropertiesViewModel(entries: [file], supplement: theirs(0o755, owner: owner))
            let rows = rows(model)
            XCTAssertFalse(model.showsPermissionControls)
            XCTAssertFalse(model.permissionControlsEnabled)
            XCTAssertEqual(rows["Owner"]?.value, owner)
            XCTAssertEqual(rows["Others"]?.value, "Can only read")
            XCTAssertEqual(rows["Runs as Program"]?.value, "Yes")
            XCTAssertTrue(model.permissionRows.allSatisfy { $0.control == nil })
            XCTAssertNil(model.allowsExecuting)
            XCTAssertNil(model.mode(choosing: .noAccess, for: .everyone))
            XCTAssertEqual(model.permissionsFooter, "Shown as macOS keeps them. Only the owner can change these.")
        }
    }

    /// A link's own permissions aren't used, so even the person's own link is only shown.
    func testALinkIsOnlyShown() {
        let link = FileEntry(url: URL(fileURLWithPath: "/home/pat/link.txt"), kind: .symlinkToFile, size: 9)
        let model = PropertiesViewModel(entries: [link], supplement: yours(0o755, refusal: .link))
        XCTAssertFalse(model.showsPermissionControls)
        XCTAssertEqual(model.permissionsFooter, "Shown as macOS keeps them. A symbolic link uses its original’s permissions.")
        // Even when the reader's answer is missing, a link isn't changed.
        let unread = PropertiesViewModel(entries: [link], supplement: PropertiesSupplement(posixMode: 0o755, ownerIsYou: true))
        XCTAssertFalse(unread.showsPermissionControls)
        XCTAssertEqual(unread.permissionsFooter, model.permissionsFooter)
    }

    /// Locked, or on a read-only disk or one that keeps no permissions: the controls are shown, off, and say why.
    func testWhatStandsInTheWayTurnsTheControlsOff() {
        let refusals: [PermissionRefusal] = [.locked, .readOnlyVolume, .notKept]
        for refusal in refusals {
            let model = PropertiesViewModel(entries: [file], supplement: yours(0o644, refusal: refusal))
            XCTAssertTrue(model.showsPermissionControls)
            XCTAssertFalse(model.permissionControlsEnabled)
            XCTAssertEqual(model.permissionsFooter, refusal.message)
        }
        let locked = PropertiesViewModel(entries: [file], supplement: yours(0o644, refusal: .locked))
        XCTAssertEqual(rows(locked)["Locked"]?.value, "Yes")
    }

    /// While a change is made the controls wait; what a change came to is said under them until the next one.
    func testAChangeUnderWayAndWhatItCameTo() {
        let changing = PropertiesViewModel(entries: [file], supplement: yours(0o644), changingPermissions: true)
        XCTAssertTrue(changing.showsPermissionControls)
        XCTAssertFalse(changing.permissionControlsEnabled)
        let refused = PropertiesViewModel(entries: [file], supplement: yours(0o644), permissionMessage: PermissionRefusal.changed.message)
        XCTAssertEqual(refused.permissionsFooter, PermissionRefusal.changed.message)
        XCTAssertTrue(refused.permissionControlsEnabled)
    }

    /// A file nobody can read keeps its checkbox off, since turning it on would let nobody run it.
    func testTheCheckboxIsOffWhereItWouldChangeNothing() {
        let unreadable = PropertiesViewModel(entries: [file], supplement: yours(0o200))
        XCTAssertEqual(unreadable.allowsExecuting, false)
        XCTAssertFalse(unreadable.canToggleExecuting)
        let running = PropertiesViewModel(entries: [file], supplement: yours(0o711))
        XCTAssertEqual(running.allowsExecuting, true)
        XCTAssertTrue(running.canToggleExecuting)
        XCTAssertEqual(running.mode(allowingExecution: false), 0o600)
    }

    /// Several items have no permissions to show, and nothing to change.
    func testSeveralItemsHaveNoPermissions() {
        let model = PropertiesViewModel(entries: [file, folder], supplement: yours(0o644), permissionMessage: "x")
        XCTAssertTrue(model.permissionRows.isEmpty)
        XCTAssertFalse(model.showsPermissionControls)
        XCTAssertNil(model.permissionsFooter)
        XCTAssertNil(model.mode(choosing: .noAccess, for: .group))
    }
}
