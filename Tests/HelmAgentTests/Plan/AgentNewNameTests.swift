import XCTest
import HelmCore
@testable import HelmAgent

/// The one rule for names a model writes, and the extension rules that keep a plan from making something that runs.
final class AgentNewNameTests: XCTestCase {
    private func passes(_ result: Result<ValidFileName, AgentToolCode>, _ expected: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success(let name): XCTAssertEqual(name.value, expected, file: file, line: line)
        case .failure(let code): XCTFail("\(expected) was refused: \(code)", file: file, line: line)
        }
    }

    private func refused(_ result: Result<ValidFileName, AgentToolCode>, _ label: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success(let name): XCTFail("\(label) passed as \(name.value)", file: file, line: line)
        case .failure(let code): XCTAssertEqual(code, .name_not_allowed, label, file: file, line: line)
        }
    }

    // MARK: The shared rule

    func testOneComponentWithNoPortableTroubleCharacterPasses() {
        passes(AgentNewName.validate("Reports 2026"), "Reports 2026")
        passes(AgentNewName.validate("Café"), "Café")
        passes(AgentNewName.validate("Ünïcode – ok"), "Ünïcode – ok")
        passes(AgentNewName.validate("a.b"), "a.b")
        for text in ["a/b", "/", "a\\b", "a:b", "a*b", "a?b", "a\"b", "a<b", "a>b", "a|b", "a\0b", "", ".", ".."] {
            refused(AgentNewName.validate(text), text.debugDescription)
        }
    }

    func testLeadingAndTrailingTroubleIsRefused() {
        for text in [".hidden", " lead", "trail ", "~tilde", "dot.", "\u{00A0}nbsp", "nbsp\u{00A0}", "\ttab", "tab\t"] {
            refused(AgentNewName.validate(text), text.debugDescription)
        }
        passes(AgentNewName.validate("a~b"), "a~b")
        passes(AgentNewName.validate("a .b"), "a .b")
    }

    func testHiddenCharactersAreRefused() {
        for text in ["inv\u{202E}fdp.exe", "zero\u{200B}width", "soft\u{00AD}hyphen", "line\nbreak", "bell\u{07}",
                     "sep\u{2028}line", "private\u{E000}use", "bom\u{FEFF}", "variation\u{FE0F}"] {
            refused(AgentNewName.validate(text), text.debugDescription)
        }
    }

    func testTwoHundredFiftyFiveBytesAtMost() {
        passes(AgentNewName.validate(String(repeating: "a", count: 255)), String(repeating: "a", count: 255))
        refused(AgentNewName.validate(String(repeating: "a", count: 256)), "256 bytes")
        // "é" is two bytes: 127 of them are 254 bytes, 128 are 256.
        passes(AgentNewName.validate(String(repeating: "é", count: 127)), String(repeating: "é", count: 127))
        refused(AgentNewName.validate(String(repeating: "é", count: 128)), "128 two-byte characters")
    }

    func testCaseAndAccentFormsClash() {
        XCTAssertEqual(AgentNewName.clashKey("Report"), AgentNewName.clashKey("REPORT"))
        XCTAssertEqual(AgentNewName.clashKey("Caf\u{E9}"), AgentNewName.clashKey("Cafe\u{301}"))
        XCTAssertEqual(AgentNewName.clashKey("CAF\u{C9}"), AgentNewName.clashKey("cafe\u{301}"))
        XCTAssertNotEqual(AgentNewName.clashKey("Cafe"), AgentNewName.clashKey("Café"))
        XCTAssertNotEqual(AgentNewName.clashKey("a"), AgentNewName.clashKey("b"))
    }

    // MARK: Extensions

    func testAnExtensionIsOneToSixteenLettersAndDigitsWithALetter() {
        XCTAssertEqual(AgentNewName.fileExtension(of: "Invoice.PDF"), "pdf")
        XCTAssertEqual(AgentNewName.fileExtension(of: "a.tar.gz"), "gz")
        XCTAssertEqual(AgentNewName.fileExtension(of: "song.mp3"), "mp3")
        XCTAssertEqual(AgentNewName.fileExtension(of: "X.app"), "app")
        XCTAssertEqual(AgentNewName.fileExtension(of: "a." + String(repeating: "x", count: 16)), String(repeating: "x", count: 16))
        XCTAssertNil(AgentNewName.fileExtension(of: "a." + String(repeating: "x", count: 17)))
        XCTAssertNil(AgentNewName.fileExtension(of: "2026.03"))
        XCTAssertNil(AgentNewName.fileExtension(of: "v1.2"))
        XCTAssertNil(AgentNewName.fileExtension(of: "plain"))
        XCTAssertNil(AgentNewName.fileExtension(of: "ends."))
        XCTAssertNil(AgentNewName.fileExtension(of: "a.my_ext"))
        XCTAssertNil(AgentNewName.fileExtension(of: "a.b c"))
    }

    func testAFileRenameKeepsItsExtension() {
        passes(AgentNewName.validateFileRename("Invoice March.pdf", from: "Scan_0042.pdf"), "Invoice March.pdf")
        passes(AgentNewName.validateFileRename("archive.tar.gz", from: "a.gz"), "archive.tar.gz")
        passes(AgentNewName.validateFileRename("notes", from: "draft"), "notes")
        passes(AgentNewName.validateFileRename("2026.04", from: "2026.03"), "2026.04")
        refused(AgentNewName.validateFileRename("Invoice.txt", from: "Scan.pdf"), "changes the extension")
        refused(AgentNewName.validateFileRename("Invoice.app", from: "Scan.pdf"), "changes it to one that runs")
        refused(AgentNewName.validateFileRename("Invoice.pdf.command", from: "Scan.pdf"), "adds one after it")
        refused(AgentNewName.validateFileRename("Invoice", from: "Scan.pdf"), "removes it")
        refused(AgentNewName.validateFileRename("notes.app", from: "notes"), "adds one")
        refused(AgentNewName.validateFileRename("notes.v2", from: "notes"), "adds one with a digit")
        refused(AgentNewName.validateFileRename("a/b.pdf", from: "Scan.pdf"), "a slash")
    }

    func testAFileRenameThatChangesOnlyTheExtensionsCasePasses() {
        passes(AgentNewName.validateFileRename("Scan.PDF", from: "Scan.pdf"), "Scan.PDF")
        passes(AgentNewName.validateFileRename("invoice.Pdf", from: "SCAN.pdf"), "invoice.Pdf")
    }

    func testAFolderCantTakeOnAnExtension() {
        refused(AgentNewName.validateFolderName("X.app", existing: nil), "X.app as a new folder")
        refused(AgentNewName.validateFolderName("Tools.command", existing: nil), "a new .command folder")
        refused(AgentNewName.validateFolderName("Stuff.app", existing: "Stuff"), "renamed to .app")
        refused(AgentNewName.validateFolderName("Stuff.APP", existing: "Stuff"), "renamed to .APP")
        refused(AgentNewName.validateFolderName("Stuff.command", existing: "Stuff"), "renamed to .command")
        refused(AgentNewName.validateFolderName("New.command", existing: "Old.app"), "a different extension")
        refused(AgentNewName.validateFolderName(".app", existing: nil), "a leading dot")
    }

    func testFolderNamesWithDotsThatAreNotExtensionsPass() {
        passes(AgentNewName.validateFolderName("2026.03", existing: nil), "2026.03")
        passes(AgentNewName.validateFolderName("v1.2", existing: nil), "v1.2")
        passes(AgentNewName.validateFolderName("Photos", existing: nil), "Photos")
        passes(AgentNewName.validateFolderName("Q1 2026.03", existing: "Old"), "Q1 2026.03")
    }

    func testAFolderThatAlreadyEndsInAnExtensionKeepsIt() {
        passes(AgentNewName.validateFolderName("New.app", existing: "Old.app"), "New.app")
        passes(AgentNewName.validateFolderName("New.APP", existing: "Old.app"), "New.APP")
        passes(AgentNewName.validateFolderName("New", existing: "Old.app"), "New")
    }
}
