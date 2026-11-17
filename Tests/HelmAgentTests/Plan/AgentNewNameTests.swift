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

    // MARK: New files

    func testANewFileIsTextCodeOrADocumentHelmMakesFromText() {
        for name in ["Packing List.txt", "Notes.md", "Read Me.markdown", "Budget.csv", "Scores.tsv", "data.json", "site.yaml",
                     "index.html", "style.css", "main.swift", "tool.py", "build.sh", "query.sql", "Letter.rtf", "Report.docx",
                     "LOUD.TXT", "Report.DOCX", "v1.2 notes.txt"] {
            passes(AgentNewName.validateNewFileName(name), name)
        }
    }

    func testANewFileCantBeSomethingThatRunsOpensAnAddressOrInstalls() {
        for name in ["launch.command", "run.tool", "Shell.terminal", "Tool.app", "Do It.workflow", "script.scpt",
                     "site.webloc", "server.inetloc", "page.url", "settings.plist", "profile.mobileconfig", "Setup.pkg",
                     "Disk.dmg", "setup.exe", "lib.dylib", "Thing.applescript", "Quick.shortcut", "notes.txt.command"] {
            refused(AgentNewName.validateNewFileName(name), name)
        }
        // Nor anything Helm doesn't write as text: pictures, PDFs, archives, other office files.
        for name in ["photo.png", "scan.pdf", "backup.zip", "sheet.xlsx", "slides.key", "old.doc", "book.pages"] {
            refused(AgentNewName.validateNewFileName(name), name)
        }
    }

    func testANewFileNeedsAVisibleNameWithAnExtension() {
        for name in [".env", ".hidden.txt", "README", "notes.", "2026.03", "a/b.txt", "~notes.txt", " notes.txt", "notes.txt ",
                     "", "..", "note\u{202E}txt.md"] {
            refused(AgentNewName.validateNewFileName(name), name.isEmpty ? "empty" : name)
        }
        XCTAssertFalse(AgentNewName.isNewFileExtension(nil))
        XCTAssertTrue(AgentNewName.isNewFileExtension("docx"))
        XCTAssertFalse(AgentNewName.isNewFileExtension("command"))
    }

    func testDocumentsAreOneTierAndCodeAndWebPagesTheOther() {
        for name in ["a.txt", "a.text", "a.md", "a.markdown", "a.csv", "a.tsv", "a.json", "a.yaml", "a.yml", "a.rtf",
                     "a.docx", "a.log", "LOUD.TXT", "Report.DOCX"] {
            passes(AgentNewName.validateNewFileName(name), name)
            XCTAssertFalse(AgentNewName.isNewFileCode(name), name)
        }
        // The rest of the text and code kinds, web pages among them.
        for name in ["index.html", "page.htm", "style.css", "main.swift", "tool.py", "build.sh", "query.sql", "app.mjs",
                     "app.cjs", "app.ts", "view.tsx", "feed.xml", "site.toml", "setup.ini", "paper.tex", "film.srt",
                     "Notebook.ipynb", "INDEX.HTML"] {
            passes(AgentNewName.validateNewFileName(name), name)
            XCTAssertTrue(AgentNewName.isNewFileCode(name), name)
        }
    }

    func testScriptsThatRunOnADoubleClickOnWindowsAreRefused() {
        for name in ["run.bat", "run.cmd", "setup.ps1", "x.vbs", "x.vbe", "x.wsf", "x.wsh", "x.hta", "app.js", "APP.JS",
                     "Run.Bat"] {
            refused(AgentNewName.validateNewFileName(name), name)
        }
        for ext in ["bat", "cmd", "ps1", "vbs", "vbe", "wsf", "wsh", "hta", "js"] {
            XCTAssertFalse(AgentNewName.isNewFileExtension(ext), ext)
        }
    }

    func testNamesThatRunOnARoutineCommandOrThatWindowsReadsAreRefused() {
        for name in ["conftest.py", "setup.py", "sitecustomize.py", "usercustomize.py", "package.json", "pyproject.toml",
                     "setup.cfg", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
                     "CMakeLists.txt", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml",
                     "vite.config.ts", "jest.config.mjs", "Tailwind.Config.cjs", "webpack.config.js", "desktop.ini",
                     "autorun.inf", "Package.JSON", "cmakelists.TXT", "Desktop.ini", "AUTORUN.INF", "SETUP.PY"] {
            refused(AgentNewName.validateNewFileName(name), name)
            XCTAssertTrue(AgentNewName.isRefusedFileName(name), name)
        }
        // Names that only look like them pass.
        for name in ["package notes.json", "setup notes.py", "my.config.json", "compose.md", "Docker Compose.txt",
                     "config.ts", "desktop.txt", "CMakeLists.md"] {
            passes(AgentNewName.validateNewFileName(name), name)
        }
    }

    func testNamesWindowsKeepsForDevicesAreRefusedWhateverFollowsTheDot() {
        for name in ["CON.txt", "con.md", "Prn.csv", "aux.json", "NUL.log", "nul.tar.txt", "COM1.txt", "com9.md",
                     "LPT1.txt", "lpt9.log", "con .txt"] {
            refused(AgentNewName.validateNewFileName(name), name)
        }
        for name in ["COM10.txt", "LPT0.txt", "console.txt", "Contacts.csv", "auxiliary.md", "con-notes.md", "null.txt",
                     "com.txt", "a.con.txt"] {
            passes(AgentNewName.validateNewFileName(name), name)
        }
    }

    func testARenameCantGiveAFileARefusedName() {
        // A file a plan made as a document can't become one that runs on an install or a build.
        refused(AgentNewName.validateFileRename("package.json", from: "notes.json"), "package.json")
        refused(AgentNewName.validateFileRename("CMakeLists.txt", from: "notes.txt"), "CMakeLists.txt")
        refused(AgentNewName.validateFileRename("conftest.py", from: "tool.py"), "conftest.py")
        refused(AgentNewName.validateFileRename("vite.config.ts", from: "tool.ts"), "vite.config.ts")
        refused(AgentNewName.validateFileRename("CON.txt", from: "notes.txt"), "CON.txt")
        passes(AgentNewName.validateFileRename("package notes.json", from: "notes.json"), "package notes.json")
    }
}
