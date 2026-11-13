import XCTest
@testable import HelmCore

/// The one parser for a server address AI mode may hand to macOS: a file share, and nothing that could be anything else.
final class ServerLocationTests: XCTestCase {
    private func refused(_ text: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(ServerLocation(text), "\(why): \(text.prefix(80))", file: file, line: line)
    }

    func testFileSharingSchemesAreAccepted() throws {
        let smb = try XCTUnwrap(ServerLocation("smb://nas.local/Media"))
        XCTAssertEqual(smb.scheme, "smb")
        XCTAssertEqual(smb.host, "nas.local")
        XCTAssertEqual(smb.share, "Media")
        XCTAssertEqual(smb.folders, [])
        XCTAssertEqual(smb.url.absoluteString, "smb://nas.local/Media")

        let afp = try XCTUnwrap(ServerLocation("afp://timecapsule/Data/Backups"))
        XCTAssertEqual([afp.scheme, afp.host, afp.share], ["afp", "timecapsule", "Data"])
        XCTAssertEqual(afp.folders, ["Backups"])
        XCTAssertEqual(afp.url.absoluteString, "afp://timecapsule/Data/Backups")

        let nfs = try XCTUnwrap(ServerLocation("nfs://192.168.1.20/volume1/media/films"))
        XCTAssertEqual([nfs.scheme, nfs.host, nfs.share], ["nfs", "192.168.1.20", "volume1"])
        XCTAssertEqual(nfs.folders, ["media", "films"])
        XCTAssertEqual(nfs.url.absoluteString, "nfs://192.168.1.20/volume1/media/films")
    }

    func testCIFSIsReadAsSMB() throws {
        let location = try XCTUnwrap(ServerLocation("cifs://nas/share"))
        XCTAssertEqual(location.scheme, "smb")
        XCTAssertEqual(location.url.scheme, "smb")
        XCTAssertEqual(location.url.absoluteString, "smb://nas/share")
        XCTAssertEqual(location, ServerLocation("smb://nas/share"))
    }

    func testTheHostIsLowerCaseAndTheShareKeepsItsCase() throws {
        let location = try XCTUnwrap(ServerLocation("SMB://NAS.Local/Media/Films"))
        XCTAssertEqual(location.scheme, "smb")
        XCTAssertEqual(location.host, "nas.local")
        XCTAssertEqual(location.share, "Media")
        XCTAssertEqual(location.folders, ["Films"])
        XCTAssertEqual(try XCTUnwrap(ServerLocation("smb://my_nas-2/share")).host, "my_nas-2")
    }

    func testSpacesAndEscapesInNames() throws {
        // Typed with a space, or with the space written as an escape: one share either way.
        let typed = try XCTUnwrap(ServerLocation("smb://nas/My Share/Tax Returns"))
        let escaped = try XCTUnwrap(ServerLocation("smb://nas/My%20Share/Tax%20Returns"))
        XCTAssertEqual(typed, escaped)
        XCTAssertEqual(typed.share, "My Share")
        XCTAssertEqual(typed.folders, ["Tax Returns"])
        XCTAssertEqual(typed.url.absoluteString, "smb://nas/My%20Share/Tax%20Returns")
        XCTAssertEqual(typed.url.path, "/My Share/Tax Returns")
        // One slash after the last name, and spaces round the whole address, change nothing.
        XCTAssertEqual(ServerLocation("  smb://nas/share/  "), ServerLocation("smb://nas/share"))
        XCTAssertEqual(try XCTUnwrap(ServerLocation("smb://nas/Ärchiv")).share, "Ärchiv")
        // A question mark written as an escape is part of a name, and stays escaped in the address.
        let odd = try XCTUnwrap(ServerLocation("smb://nas/what%3F"))
        XCTAssertEqual(odd.share, "what?")
        XCTAssertNil(odd.url.query)
        XCTAssertEqual(odd.url.absoluteString, "smb://nas/what%3F")
    }

    func testOtherSchemesAreRefused() {
        for scheme in ["http", "https", "ftp", "ftps", "sftp", "vnc", "webdav", "webdavs", "dav", "file", "ssh", "telnet",
                       "rdp", "ws", "javascript", "x-apple.systempreferences", "mailto", ""] {
            refused("\(scheme)://nas.local/share", "the scheme \(scheme)")
        }
        // Not an address at all.
        for text in ["", "nas.local/share", "smb:nas/share", "smb:/nas/share", "//nas/share", "/Volumes/share", "~/share",
                     "smb", "connect to smb://nas/share", "smb ://nas/share"] {
            refused(text, "not a server address")
        }
    }

    func testANameOrAPasswordIsRefused() {
        refused("smb://rene@nas.local/share", "a name")
        refused("smb://rene:hunter2@nas.local/share", "a name and a password")
        refused("smb://:hunter2@nas.local/share", "a password")
        refused("smb://WORKGROUP;rene@nas.local/share", "a domain and a name")
        refused("smb://rene%40home@nas.local/share", "a name written with an escape")
        refused("smb://@nas.local/share", "an empty name")
    }

    func testAPortAQueryOrAFragmentIsRefused() {
        refused("smb://nas.local:445/share", "a port")
        refused("smb://nas.local:/share", "an empty port")
        refused("smb://[fe80::1]/share", "an address with colons")
        refused("smb://nas.local/share?mount=/Applications", "a query")
        refused("smb://nas.local/share?", "an empty query")
        refused("smb://nas.local?x/share", "a query before the share")
        refused("smb://nas.local/share#top", "a fragment")
        refused("smb://nas.local#x/share", "a fragment before the share")
    }

    func testAHostThatIsNotAPlainNameIsRefused() {
        for host in ["", ".", "nas..local", ".nas", "nas.", "nas local", "nas%20local", "ñas.local", "nas\u{2024}local", "näs", "*", "nas,local"] {
            refused("smb://\(host)/share", "the host \(host)")
        }
    }

    func testAShareIsNeededAndAtMostTwoFoldersBelowIt() {
        refused("smb://nas.local", "no share")
        refused("smb://nas.local/", "no share")
        refused("smb://nas.local//share", "an empty name")
        refused("smb://nas.local/share//folder", "an empty name")
        refused("smb://nas.local/share/a/b/c", "a third folder")
        refused("smb://nas.local/share/a/b/c/", "a third folder")
        refused("smb://nas.local/share/a/b//", "two slashes at the end")
        XCTAssertNotNil(ServerLocation("smb://nas.local/share/a/b"))
        XCTAssertNotNil(ServerLocation("smb://nas.local/share/a/b/"))
        // A name can't climb out of the share or smuggle a slash in.
        refused("smb://nas.local/share/..", "a climbing part")
        refused("smb://nas.local/../share", "a climbing part")
        refused("smb://nas.local/./share", "a dot part")
        refused("smb://nas.local/share/%2E%2E", "a climbing part written with escapes")
        refused("smb://nas.local/share/a%2Fb", "a slash written with an escape")
        refused("smb://nas.local/share/100%", "a broken escape")
    }

    func testLengthIsLimitedTo255Characters() {
        let prefix = "smb://nas.local/share/"
        let longest = prefix + String(repeating: "a", count: 255 - prefix.count)
        XCTAssertEqual(longest.count, 255)
        XCTAssertNotNil(ServerLocation(longest))
        XCTAssertEqual(ServerLocation(longest)?.folders.first?.count, 255 - prefix.count)
        refused(longest + "a", "256 characters")
        refused(prefix + String(repeating: "a", count: 4_000), "far too long")
    }

    func testControlAndHiddenCharactersAreRefused() {
        refused("smb://nas.local/sha\nre", "a line break")
        refused("smb://nas.local/share\u{0}", "a NUL")
        refused("smb://nas.local/sha\tre", "a tab")
        refused("smb://nas.local/sha\u{7F}re", "a delete character")
        refused("smb://nas\u{200B}.local/share", "a zero-width space in the host")
        refused("smb://nas.local/share\u{202E}fdp", "a character that reverses the reading order")
        refused("smb://nas.local/sha\u{2028}re", "a line separator")
        refused("s\u{AD}mb://nas.local/share", "a soft hyphen in the scheme")
        // The same characters written as escapes are refused once read.
        refused("smb://nas.local/sha%0Are", "a line break written with an escape")
        refused("smb://nas.local/share%00", "a NUL written with an escape")
        refused("smb://nas.local/share%E2%80%AEfdp", "a reversing character written with an escape")
    }

    func testOnlyTheThreeSchemesCanBeHeld() {
        XCTAssertEqual(Set(ServerLocation.schemes.values), ["smb", "afp", "nfs"])
        XCTAssertEqual(Set(ServerLocation.schemes.keys), ["smb", "cifs", "afp", "nfs"])
        // Whatever was typed, the address handed on is built from the parts, so its scheme is one of the three.
        for text in ["smb://nas/share", "CIFS://NAS/share/a", "afp://nas/share/a/b", "nfs://10.0.0.2/export"] {
            let location = ServerLocation(text)
            XCTAssertNotNil(location, text)
            XCTAssertTrue(["smb", "afp", "nfs"].contains(location?.url.scheme ?? ""), text)
            XCTAssertEqual(location?.url.host, location?.host, text)
            XCTAssertNil(location?.url.user, text)
            XCTAssertNil(location?.url.password, text)
            XCTAssertNil(location?.url.port, text)
            XCTAssertNil(location?.url.query, text)
            XCTAssertNil(location?.url.fragment, text)
        }
    }
}
