// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
@testable import HelmCore

final class PermissionsModelTests: XCTestCase {
    func testEveryModeAndRowRoundTripsAndPreservesUnrelatedBits() {
        for mode: UInt16 in 0...0o7777 {
            var model = PermissionsModel(modes: [mode])
            for subject in PermissionSubject.allCases {
                let access = PermissionAccess(bits: mode >> subject.rawValue)
                XCTAssertEqual(model.row(subject), .value(access))
                model.set(access, for: subject)
            }
            XCTAssertEqual(model.applying(to: mode), mode)
            XCTAssertFalse(model.isDirty)
            for subject in PermissionSubject.allCases {
                for bits: UInt16 in 0...7 {
                    var edited = model
                    edited.set(PermissionAccess(bits: bits), for: subject)
                    let mask = UInt16(7) << subject.rawValue
                    XCTAssertEqual(edited.applying(to: mode) & ~mask, mode & ~mask)
                    XCTAssertEqual((edited.applying(to: mode) & mask) >> subject.rawValue, bits)
                }
            }
        }
    }
    func testLabelsAndExecuteAreIndependent() {
        let labels = ["No Access", "No Access", "Write only", "Write only", "Read only", "Read only", "Read & Write", "Read & Write"]
        for bits: UInt16 in 0...7 {
            let access = PermissionAccess(bits: bits)
            XCTAssertEqual(access.bits, bits)
            XCTAssertEqual(access.finderLabel, labels[Int(bits)])
            XCTAssertEqual(access.execute, bits & 1 == 1)
        }
    }
    func testMixedEmptyResetAndRecursiveIntent() {
        var model = PermissionsModel(modes: [0o644, 0o744])
        XCTAssertEqual(model.row(.owner), .mixed)
        XCTAssertEqual(model.row(.owner).mixedLabel, "mixed")
        XCTAssertEqual(model.row(.group), .value(PermissionAccess(bits: 4)))
        model.set(PermissionAccess(bits: 7), for: .owner)
        XCTAssertEqual(model.row(.owner), .value(PermissionAccess(bits: 7)))
        XCTAssertTrue(model.isDirty)
        model.reset()
        XCTAssertFalse(model.isDirty)
        model.applyToEnclosedItems = true
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(PermissionsModel(modes: []).row(.owner), .unavailable)
        XCTAssertNil(InspectorValue(values: [true]).mixedLabel)
    }
}
