import Foundation
import XCTest
@testable import HelmCore

final class NamingTests: XCTestCase {
    func testValidationAndWhitespace() throws {
        let failures: [(String, FileNameError)] = [("", .empty), (" \t ", .empty), ("a/b", .separator),
            ("../x", .separator), ("a\0b", .nul), (".", .dot), ("..", .dot),
            (String(repeating: "a", count: 256), .tooLong), (String(repeating: "😀", count: 64), .tooLong)]
        for (raw, error) in failures {
            XCTAssertEqual(FileNameValidator.validate(raw), .failure(error), raw)
            XCTAssertNil(ValidFileName(raw))
        }
        for raw in ["a:b", "مرحبا", "é", "e\u{301}", "😀", "line\nbreak", String(repeating: "a", count: 255)] {
            XCTAssertEqual(try FileNameValidator.validate(raw).get().value, raw)
        }
        XCTAssertEqual(ValidFileName("  name  ")?.value, "name")
        XCTAssertEqual(ValidFileName(" .hidden ")?.isHidden, true)
        XCTAssertEqual(ValidFileName("name")?.isHidden, false)
    }

    func testCodableCannotBypassValidation() throws {
        let name = try XCTUnwrap(ValidFileName(".hello"))
        XCTAssertEqual(try JSONDecoder().decode(ValidFileName.self, from: JSONEncoder().encode(name)), name)
        for raw in ["../escape", "", "\0"] {
            XCTAssertThrowsError(try JSONDecoder().decode(ValidFileName.self, from: JSONEncoder().encode(raw)))
        }
    }

    func testComparison() {
        XCTAssertEqual(FileNameComparison.key("É", caseSensitive: false), FileNameComparison.key("e\u{301}", caseSensitive: false))
        XCTAssertNotEqual(FileNameComparison.key("A", caseSensitive: true), FileNameComparison.key("a", caseSensitive: true))
        XCTAssertEqual(FileNameComparison.key("é", caseSensitive: true), FileNameComparison.key("e\u{301}", caseSensitive: true))
        XCTAssertNotEqual(FileNameComparison.key("a ", caseSensitive: false), FileNameComparison.key("a", caseSensitive: false))
    }

    func testLegacyUniqueSuffixes() throws {
        for (raw, expected) in [("name.ext", "name 2.ext"), (".hidden", ".hidden 2"),
                                ("a.tar.gz", "a.tar 2.gz"), ("New Folder", "New Folder 2"), ("😀.txt", "😀 2.txt")] {
            XCTAssertEqual(try UniqueNamer.name(for: raw, existingNames: [raw]).value, expected)
        }
        XCTAssertEqual(try UniqueNamer.name(for: "a.txt", existingNames: ["A.TXT", "a 2.txt"]).value, "a 3.txt")
        XCTAssertEqual(try UniqueNamer.name(for: "a", existingNames: ["A"], caseSensitive: true).value, "a")
        XCTAssertEqual(try UniqueNamer.name(for: "é", existingNames: ["e\u{301}"]).value, "é 2")
        XCTAssertEqual(try UniqueNamer.name(for: " a ", exists: { _ in false }).value, "a")
        XCTAssertThrowsError(try UniqueNamer.name(for: "a/b", existingNames: []))
        let long = String(repeating: "😀", count: 63)
        let result = try UniqueNamer.name(for: long, existingNames: [long])
        XCTAssertLessThanOrEqual(result.value.utf8.count, 255)
        XCTAssertTrue(result.value.hasSuffix(" 2"))
        let maxName = String(repeating: "a", count: 255)
        XCTAssertEqual(try UniqueNamer.name(for: maxName, existingNames: [maxName]).value.utf8.count, 255)
    }

    func testRulesPreserveBasenamesAndTokens() throws {
        let date = Date(timeIntervalSince1970: 0)
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(try BatchRenameRule.addText(prepend: "pre-", append: "-post").name(for: "a.tar.gz", index: 0, date: date), "pre-a.tar-post.gz")
        XCTAssertEqual(try BatchRenameRule.findReplace(find: "a", replacement: "b").name(for: "aaa.a", index: 0, date: date), "bbb.a")
        XCTAssertEqual(try BatchRenameRule.findReplace(find: "", replacement: "b").name(for: ".hidden", index: 0, date: date), ".hidden")
        XCTAssertEqual(try BatchRenameRule.template("[Original Name]-[Counter]-[Date]-[Unknown]", counterStart: -1)
            .name(for: "a.txt", index: 2, date: date, timeZone: zone), "a-1-1970-01-01-[Unknown].txt")
        XCTAssertThrowsError(try BatchRenameRule.template("[Counter]", counterStart: Int.max).name(for: "a", index: 1, date: date))
        XCTAssertEqual(RenameToken.allCases.count, 3)
    }
}
