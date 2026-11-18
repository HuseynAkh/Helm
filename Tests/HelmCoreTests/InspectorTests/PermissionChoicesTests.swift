import XCTest
import HelmCore

/// Finder's three choices for a class of user, as Properties maps them onto a mode, and Nautilus's execute checkbox.
final class PermissionChoicesTests: XCTestCase {
    func testFinderWords() {
        XCTAssertEqual(FinderAccess.allCases.map(\.title), ["Read & Write", "Read only", "No access"])
    }

    /// A folder's choices are rwx, r-x and ---: it can't be opened without execute. Any other mix is Custom.
    func testAFoldersChoicesIncludeExecute() {
        let read = (0...7).map { FinderAccess(bits: UInt16($0), folder: true) }
        XCTAssertEqual(read, [.noAccess, nil, nil, nil, nil, .readOnly, nil, .readWrite])
        XCTAssertEqual(FinderAccess.allCases.map { $0.bits(folder: true, keepingExecuteOf: 0) }, [7, 5, 0])
        XCTAssertEqual(FinderAccess.allCases.map { $0.bits(folder: true, keepingExecuteOf: 1) }, [7, 5, 0])
    }

    /// A file's choices are about reading and writing. Its execute bit is kept as it was, and plays no part in which
    /// choice it shows. Write-only is Custom.
    func testAFilesChoicesKeepItsExecuteBit() {
        let read = (0...7).map { FinderAccess(bits: UInt16($0), folder: false) }
        XCTAssertEqual(read, [.noAccess, .noAccess, nil, nil, .readOnly, .readOnly, .readWrite, .readWrite])
        XCTAssertEqual(FinderAccess.allCases.map { $0.bits(folder: false, keepingExecuteOf: 0) }, [6, 4, 0])
        XCTAssertEqual(FinderAccess.allCases.map { $0.bits(folder: false, keepingExecuteOf: 1) }, [7, 5, 1])
        XCTAssertEqual(FinderAccess.allCases.map { $0.bits(folder: false, keepingExecuteOf: 6) }, [6, 4, 0])
    }

    /// Every choice, made from every mode, shows as that choice afterwards, and leaves every other bit as it was:
    /// the other classes, set-user-ID, set-group-ID and sticky, and a file's execute bit.
    func testEveryChoiceFromEveryModeRoundTripsAndKeepsEverythingElse() {
        for mode: UInt16 in 0...0o7777 {
            for subject in PermissionSubject.allCases {
                let shift = UInt16(subject.rawValue)
                let others = ~(UInt16(7) << shift)
                for access in FinderAccess.allCases {
                    for folder in [false, true] {
                        let changed = PermissionEdit.mode(mode, setting: access, for: subject, folder: folder)
                        XCTAssertEqual(FinderAccess(bits: changed >> shift, folder: folder), access)
                        XCTAssertEqual(changed & others, mode & others)
                        if !folder { XCTAssertEqual((changed >> shift) & 1, (mode >> shift) & 1) }
                    }
                }
            }
        }
    }

    func testChoicesOnModes() {
        XCTAssertEqual(PermissionEdit.mode(0o644, setting: .noAccess, for: .group, folder: false), 0o604)
        XCTAssertEqual(PermissionEdit.mode(0o755, setting: .noAccess, for: .everyone, folder: false), 0o751)
        XCTAssertEqual(PermissionEdit.mode(0o755, setting: .noAccess, for: .everyone, folder: true), 0o750)
        XCTAssertEqual(PermissionEdit.mode(0o750, setting: .readWrite, for: .group, folder: true), 0o770)
        XCTAssertEqual(PermissionEdit.mode(0o624, setting: .readOnly, for: .group, folder: false), 0o644)
        XCTAssertEqual(PermissionEdit.mode(0o1777, setting: .readOnly, for: .everyone, folder: true), 0o1775)
        XCTAssertEqual(PermissionEdit.mode(0o4755, setting: .readWrite, for: .owner, folder: false), 0o4755)
    }

    /// "Allow executing file as program" is on while anyone may run the file. On lets each class that can read it run
    /// it; off lets nobody, and leaves every other bit as it was.
    func testTheExecuteCheckbox() {
        XCTAssertFalse(PermissionEdit.allowsExecuting(0o644))
        XCTAssertTrue(PermissionEdit.allowsExecuting(0o744))
        XCTAssertTrue(PermissionEdit.allowsExecuting(0o601))
        XCTAssertEqual(PermissionEdit.mode(0o644, allowingExecution: true), 0o755)
        XCTAssertEqual(PermissionEdit.mode(0o640, allowingExecution: true), 0o750)
        XCTAssertEqual(PermissionEdit.mode(0o604, allowingExecution: true), 0o705)
        XCTAssertEqual(PermissionEdit.mode(0o200, allowingExecution: true), 0o200)
        XCTAssertEqual(PermissionEdit.mode(0o755, allowingExecution: false), 0o644)
        XCTAssertEqual(PermissionEdit.mode(0o4751, allowingExecution: false), 0o4640)
        for mode: UInt16 in 0...0o7777 {
            let off = PermissionEdit.mode(mode, allowingExecution: false)
            XCTAssertFalse(PermissionEdit.allowsExecuting(off))
            XCTAssertEqual(off | 0o111, mode | 0o111)
            let on = PermissionEdit.mode(off, allowingExecution: true)
            XCTAssertEqual(on & ~UInt16(0o111), off)
            // Execute for exactly the classes that can read it.
            XCTAssertEqual(on & 0o111, (off & 0o444) >> 2)
        }
    }

    func testEveryRefusalSaysSomething() {
        let refusals: [PermissionRefusal] = [.notOwner, .locked, .readOnlyVolume, .notKept, .link, .changed, .missing,
                                             .notPermitted, .failed("Inappropriate file type or format")]
        for refusal in refusals { XCTAssertFalse(refusal.message.isEmpty) }
        XCTAssertEqual(PermissionRefusal.notOwner.message, "Only the owner can change these.")
        XCTAssertEqual(PermissionRefusal.failed("Bad").message, "Its permissions couldn’t be changed: Bad.")
    }
}
