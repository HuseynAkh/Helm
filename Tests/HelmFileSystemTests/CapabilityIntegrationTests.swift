// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore
import HelmFileSystem
import HelmTestKit

final class CapabilityIntegrationTests: XCTestCase {
    func testFakeSensitivityAndExclusiveCollision() async throws {
        let url = URL(fileURLWithPath: "/name")
        for sensitive in [true, false] {
            let fs = InMemoryFileSystem(caseSensitive: sensitive)
            let capability = try await fs.isCaseSensitive(at: url)
            XCTAssertEqual(capability, sensitive)
            try await fs.createFileExclusively(at: url, contents: Data([1]))
            do {
                try await fs.createFileExclusively(at: url, contents: Data([2]))
                XCTFail("Collision was accepted")
            } catch { XCTAssertEqual(error as? FileSystemError, .collision(noMutation: true)) }
            let entry = try await fs.entry(at: url)
            XCTAssertEqual(entry.size, 1)
        }
    }

    func testGenericCollisionMappingDoesNotPromiseNoMutation() {
        for error in [NSError(domain: NSPOSIXErrorDomain, code: 17), NSError(domain: NSCocoaErrorDomain, code: 516)] {
            XCTAssertEqual(FileSystemError.mapping(error), .collision(noMutation: false))
        }
        XCTAssertEqual(FileSystemError.mapping(FileSystemError.collision(noMutation: true)), .collision(noMutation: true))
    }

    func testLiveExclusiveCollisionPreservesExistingContents() async throws {
        let temporary = try TempDirectory()
        defer { try? temporary.remove() }
        let fs = LiveFileSystem()
        let url = temporary.url.appendingPathComponent("file")
        try await fs.createFileExclusively(at: url, contents: Data([1, 2]))
        do {
            try await fs.createFileExclusively(at: url, contents: Data([9]))
            XCTFail("Collision was accepted")
        } catch { XCTAssertEqual(error as? FileSystemError, .collision(noMutation: true)) }
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2]))
        do {
            try await fs.createDirectory(at: temporary.url)
            XCTFail("Existing directory was accepted")
        } catch { XCTAssertEqual(error as? FileSystemError, .collision(noMutation: true)) }
        #if os(Linux)
        let sensitive = try await fs.isCaseSensitive(at: temporary.url)
        XCTAssertTrue(sensitive)
        let entry = try await fs.entry(at: url)
        XCTAssertEqual(entry.cloudAvailability, .unknown)
        #endif
    }

    func testPartialFakeCopyCannotPromiseNoMutation() async throws {
        let fs = InMemoryFileSystem()
        let source = URL(fileURLWithPath: "/source")
        let target = URL(fileURLWithPath: "/target")
        try await fs.createDirectory(at: source)
        try await fs.createFileExclusively(at: source.appendingPathComponent("child"), contents: Data())
        await fs.setFailure(.collision(noMutation: true), at: target.appendingPathComponent("child"))
        do {
            try await fs.copyItem(at: source, to: target)
            XCTFail("Injected collision ignored")
        } catch { XCTAssertEqual(error as? FileSystemError, .collision(noMutation: false)) }
        let exists = await fs.exists(target)
        XCTAssertTrue(exists)
    }
}
