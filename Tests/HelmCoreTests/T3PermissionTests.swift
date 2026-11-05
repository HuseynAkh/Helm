// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

/// F-050: seeded independent bit-mask oracles exercise F11 whole-mode/row draft consistency.
final class T3PermissionTests: XCTestCase {
    private func verify(_ subject: PermissionSubject, bits: UInt16) throws {
        var seed: UInt64 = 0x7A31
        for _ in 0..<64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let original = UInt16((seed >> 32) & 0o7777)
            let item = InspectorItem(url: URL(fileURLWithPath: "/folder"), isDirectory: true,
                                     attributes: [.permissions(original)], editableFields: [.permissions])
            var model = InspectorEditModel(items: [item])
            let draft: UInt16 = original ^ 0o777
            model.set(.permissions(draft))
            model.permissions.set(PermissionAccess(bits: bits), for: subject)
            let mask: UInt16 = 7 << subject.rawValue
            let expected = (draft & ~mask) | (bits << subject.rawValue)
            XCTAssertEqual(model.value(for: .permissions), .value(.permissions(expected)))
            XCTAssertEqual(model.permissions.row(subject), .value(PermissionAccess(bits: bits)))
            XCTAssertEqual(expected & 0o7000, original & 0o7000)
            let plan = try model.makePlan()
            if expected == original { XCTAssertTrue(plan.isEmpty) }
            else { XCTAssertEqual(plan.items.first?.changes.first?.proposed, .permissions(expected)) }
            model.set(.permissions(original))
            XCTAssertFalse(model.isDirty)
            XCTAssertTrue(try model.makePlan().isEmpty)
            model.applyPermissionsToEnclosedItems = true
            XCTAssertEqual(try model.makePlan().items.first?.changes.first?.applyToEnclosedItems, true)
            model.reset(.permissions)
            XCTAssertFalse(model.isDirty)
        }
    }
    func testOwnerAccess0() throws { try verify(.owner, bits: 0) }
    func testOwnerAccess1() throws { try verify(.owner, bits: 1) }
    func testOwnerAccess2() throws { try verify(.owner, bits: 2) }
    func testOwnerAccess3() throws { try verify(.owner, bits: 3) }
    func testOwnerAccess4() throws { try verify(.owner, bits: 4) }
    func testOwnerAccess5() throws { try verify(.owner, bits: 5) }
    func testOwnerAccess6() throws { try verify(.owner, bits: 6) }
    func testOwnerAccess7() throws { try verify(.owner, bits: 7) }
    func testGroupAccess0() throws { try verify(.group, bits: 0) }
    func testGroupAccess1() throws { try verify(.group, bits: 1) }
    func testGroupAccess2() throws { try verify(.group, bits: 2) }
    func testGroupAccess3() throws { try verify(.group, bits: 3) }
    func testGroupAccess4() throws { try verify(.group, bits: 4) }
    func testGroupAccess5() throws { try verify(.group, bits: 5) }
    func testGroupAccess6() throws { try verify(.group, bits: 6) }
    func testGroupAccess7() throws { try verify(.group, bits: 7) }
    func testEveryoneAccess0() throws { try verify(.everyone, bits: 0) }
    func testEveryoneAccess1() throws { try verify(.everyone, bits: 1) }
    func testEveryoneAccess2() throws { try verify(.everyone, bits: 2) }
    func testEveryoneAccess3() throws { try verify(.everyone, bits: 3) }
    func testEveryoneAccess4() throws { try verify(.everyone, bits: 4) }
    func testEveryoneAccess5() throws { try verify(.everyone, bits: 5) }
    func testEveryoneAccess6() throws { try verify(.everyone, bits: 6) }
    func testEveryoneAccess7() throws { try verify(.everyone, bits: 7) }
}
