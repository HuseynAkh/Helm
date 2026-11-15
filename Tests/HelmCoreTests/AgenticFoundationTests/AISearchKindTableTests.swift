import XCTest
@testable import HelmCore

/// The one table that decides what kind of file something is, for a model's listings, its searches and Spotlight.
final class AISearchKindTableTests: XCTestCase {
    private func kind(_ ext: String, type: String? = nil, _ entry: FileEntryKind = .regular) -> AISearchKind? {
        AISearchKind.of(typeIdentifier: type, extension: ext, kind: entry)
    }

    func testTheKindsAreTheOnesAModelIsOffered() {
        XCTAssertEqual(AISearchKind.allCases.map(\.rawValue),
                       ["folder", "document", "pdf", "image", "video", "audio", "text", "code", "spreadsheet", "presentation",
                        "archive", "app", "font"])
    }

    func testAnExtensionDecidesTheKind() {
        let table: [(String, AISearchKind)] = [
            ("pdf", .pdf), ("jpg", .image), ("jpeg", .image), ("png", .image), ("heic", .image), ("gif", .image), ("svg", .image),
            ("psd", .image), ("cr2", .image), ("mp4", .video), ("mov", .video), ("mkv", .video), ("mp3", .audio), ("m4a", .audio),
            ("wav", .audio), ("flac", .audio), ("txt", .text), ("md", .text), ("log", .text), ("json", .text), ("yaml", .text),
            ("xml", .text), ("swift", .code), ("py", .code), ("js", .code), ("ts", .code), ("html", .code), ("css", .code),
            ("sh", .code), ("c", .code), ("h", .code), ("xls", .spreadsheet), ("xlsx", .spreadsheet), ("numbers", .spreadsheet),
            ("csv", .spreadsheet), ("tsv", .spreadsheet), ("ppt", .presentation), ("pptx", .presentation), ("key", .presentation),
            ("doc", .document), ("docx", .document), ("pages", .document), ("odt", .document), ("rtf", .document),
            ("epub", .document), ("zip", .archive), ("tar", .archive), ("gz", .archive), ("7z", .archive), ("dmg", .archive),
            ("iso", .archive), ("pkg", .archive), ("ttf", .font), ("otf", .font), ("woff2", .font)
        ]
        for (ext, expected) in table {
            XCTAssertEqual(kind(ext), expected, ext)
            XCTAssertEqual(kind(ext.uppercased()), expected, "case doesn't matter: \(ext)")
            XCTAssertEqual(kind("." + ext), expected, "with its dot: \(ext)")
        }
    }

    func testAnExtensionBelongsToOneKindOnly() {
        var seen: [String: AISearchKind] = [:]
        for row in AISearchKind.extensions {
            XCTAssertFalse(row.extensions.isEmpty, row.kind.rawValue)
            for ext in row.extensions {
                XCTAssertNil(seen[ext], "\(ext) is listed under \(seen[ext]?.rawValue ?? "") and \(row.kind.rawValue)")
                seen[ext] = row.kind
                XCTAssertEqual(ext, ext.lowercased(), ext)
                XCTAssertFalse(ext.hasPrefix("."), ext)
                XCTAssertEqual(kind(ext), row.kind, ext)
            }
        }
        var identifiers: [String: AISearchKind] = [:]
        for row in AISearchKind.identifiers {
            for identifier in row.identifiers {
                XCTAssertNil(identifiers[identifier], identifier)
                identifiers[identifier] = row.kind
                XCTAssertEqual(identifier, identifier.lowercased(), identifier)
                XCTAssertEqual(kind("", type: identifier), row.kind, identifier)
            }
        }
        // Folder and app are decided by what the item is, not by a file's extension.
        XCTAssertFalse(AISearchKind.extensions.contains { $0.kind == .folder || $0.kind == .app })
        XCTAssertNil(seen["app"])
    }

    func testFoldersAppsLinksAndTheRest() {
        XCTAssertEqual(kind("", .directory), .folder)
        XCTAssertEqual(kind("pdf", .directory), .folder, "a folder is a folder whatever its name ends in")
        XCTAssertEqual(kind("app", .package), .app)
        XCTAssertEqual(kind("APP", .package), .app)
        XCTAssertEqual(kind("", type: "com.apple.application-bundle", .package), .app)
        XCTAssertNil(kind("app"), "a plain file named like an app isn't one")
        // Other packages are whatever their extension says, or nothing the table has a word for.
        XCTAssertEqual(kind("rtfd", .package), .document)
        XCTAssertEqual(kind("key", .package), .presentation)
        XCTAssertNil(kind("photoslibrary", .package))
        XCTAssertNil(kind("xcodeproj", .package))
        // A link, an alias and a device have no kind here: the caller has its own word for them.
        for entry in [FileEntryKind.symlinkToDirectory, .symlinkToFile, .danglingSymlink, .alias, .other] {
            XCTAssertNil(kind("pdf", type: "com.adobe.pdf", entry), entry.rawValue)
        }
        XCTAssertNil(kind(""))
        XCTAssertNil(kind("xyz123"))
        XCTAssertNil(kind("xyz123", type: "dyn.ah62d4rv4ge81e7dgqu"))
        XCTAssertNil(kind("", type: "public.data"))
    }

    func testTheTypeIdentifierSettlesAnExtensionTheTableDoesNotKnow() {
        XCTAssertEqual(kind("", type: "com.adobe.pdf"), .pdf)
        XCTAssertEqual(kind("", type: "public.jpeg"), .image)
        XCTAssertEqual(kind("", type: "PUBLIC.JPEG"), .image)
        XCTAssertEqual(kind("jfif", type: "public.jpeg"), .image)
        XCTAssertEqual(kind("", type: "public.plain-text"), .text)
        XCTAssertEqual(kind("", type: "public.shell-script"), .code)
        XCTAssertEqual(kind("", type: "public.zip-archive"), .archive)
        // Families the table doesn't list one by one are read from the identifier's last word.
        XCTAssertEqual(kind("x3f", type: "com.sigma.x3f-raw-image"), .image)
        XCTAssertEqual(kind("", type: "com.example.special-movie"), .video)
        XCTAssertEqual(kind("", type: "public.ulaw-audio"), .audio)
        XCTAssertEqual(kind("", type: "public.fortran-source"), .code)
        XCTAssertEqual(kind("", type: "com.example.odd-archive"), .archive)
        XCTAssertEqual(kind("", type: "com.adobe.postscript-pfb-font"), .font)
        XCTAssertEqual(kind("", type: "public.delimited-values-text"), .text)
        // A disk image is an archive, not a picture.
        XCTAssertEqual(kind("", type: "com.apple.disk-image-sparse"), .archive)
        XCTAssertEqual(kind("", type: "com.example.raw-disk-image"), .archive)
        // The extension wins when both are known: macOS reads ".ts" as a video stream.
        XCTAssertEqual(kind("ts", type: "public.mpeg-2-transport-stream"), .code)
        XCTAssertEqual(kind("", type: "public.mpeg-2-transport-stream"), .video)
    }

    func testEveryKindHasTypeIdentifiersForSpotlight() {
        for kind in AISearchKind.allCases {
            XCTAssertFalse(kind.typeIdentifiers.isEmpty, kind.rawValue)
            XCTAssertEqual(Set(kind.typeIdentifiers).count, kind.typeIdentifiers.count, kind.rawValue)
            for identifier in kind.typeIdentifiers {
                XCTAssertTrue(identifier.hasPrefix("public.") || identifier.hasPrefix("com."), identifier)
                XCTAssertEqual(identifier, identifier.lowercased())
            }
        }
        XCTAssertEqual(AISearchKind.folder.typeIdentifiers, ["public.folder"])
        XCTAssertEqual(AISearchKind.pdf.typeIdentifiers, ["com.adobe.pdf"])
        XCTAssertEqual(AISearchKind.image.typeIdentifiers, ["public.image"])
        XCTAssertEqual(AISearchKind.video.typeIdentifiers, ["public.movie"])
        XCTAssertEqual(AISearchKind.audio.typeIdentifiers, ["public.audio"])
        XCTAssertEqual(AISearchKind.text.typeIdentifiers, ["public.text"])
        XCTAssertEqual(AISearchKind.presentation.typeIdentifiers, ["public.presentation"])
        XCTAssertEqual(AISearchKind.archive.typeIdentifiers, ["public.archive", "public.disk-image"])
        XCTAssertEqual(AISearchKind.app.typeIdentifiers, ["com.apple.application"])
        XCTAssertEqual(AISearchKind.font.typeIdentifiers, ["public.font"])
        XCTAssertTrue(AISearchKind.code.typeIdentifiers.contains("public.source-code"))
        XCTAssertTrue(AISearchKind.spreadsheet.typeIdentifiers.contains("public.spreadsheet"))
    }

    /// What Spotlight is asked for and what the table answers agree: an item found by a kind's identifiers is that
    /// kind, or one the kind covers.
    func testAKindCoversWhatItsTypeIdentifiersFind() {
        for kind in AISearchKind.allCases {
            XCTAssertTrue(kind.covers(kind), kind.rawValue)
            for identifier in kind.typeIdentifiers where kind != .folder && kind != .app {
                guard let found = AISearchKind.of(typeIdentifier: identifier, extension: "", kind: .regular) else {
                    XCTFail("\(identifier) has no kind"); continue
                }
                XCTAssertTrue(kind.covers(found), "\(kind.rawValue) asks for \(identifier), which is \(found.rawValue)")
            }
        }
        // Document is the wide kind. Nothing else covers another.
        for other in AISearchKind.allCases {
            let expected = other == .document || [.pdf, .text, .spreadsheet, .presentation].contains(other)
            XCTAssertEqual(AISearchKind.document.covers(other), expected, other.rawValue)
            for kind in AISearchKind.allCases where kind != .document {
                XCTAssertEqual(kind.covers(other), kind == other, "\(kind.rawValue) and \(other.rawValue)")
            }
        }
        XCTAssertFalse(AISearchKind.text.covers(.code), "source files aren't what someone asking for text files means")
        XCTAssertFalse(AISearchKind.pdf.covers(.document))
    }
}
