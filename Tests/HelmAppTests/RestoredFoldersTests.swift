import Foundation
import XCTest
import HelmCore
import HelmFileSystem
@testable import HelmApp

/// Launch keeps restored tabs rather than waiting on them: only a folder that's gone is left out.
final class RestoredFoldersTests: XCTestCase {
    let home = URL(fileURLWithPath: "/home/test", isDirectory: true)

    private func fileSystem() async throws -> InMemoryFileSystem {
        let system = InMemoryFileSystem()
        for path in ["/home", "/home/test", "/home/test/Projects", "/home/test/Private"] {
            try await system.createDirectory(at: URL(fileURLWithPath: path, isDirectory: true))
        }
        try await system.createFileExclusively(at: home.appendingPathComponent("notes.txt"), contents: Data("x".utf8))
        return system
    }

    func testOnlyMissingFoldersAndFilesAreLeftOut() async throws {
        let system = try await fileSystem()
        let projects = home.appendingPathComponent("Projects", isDirectory: true)
        let gone = home.appendingPathComponent("Gone", isDirectory: true)
        let file = home.appendingPathComponent("notes.txt")
        let refused = home.appendingPathComponent("Private", isDirectory: true)
        await system.setFailure(.permissionDenied, at: refused)
        // macOS asks before Documents opens, so it isn't read at all: reading it could wait on that question.
        let documents = home.appendingPathComponent("Documents/Reports", isDirectory: true)
        let result = await RestoredFolders.availability(of: [projects, gone, file, refused, documents, projects],
                                                        fileSystem: system, home: home)
        XCTAssertEqual(result[projects], true)
        XCTAssertEqual(result[gone], false)
        XCTAssertEqual(result[file], false)
        // A refused folder reopens and says what's wrong, rather than losing the tab.
        XCTAssertEqual(result[refused], true)
        XCTAssertEqual(result[documents], true)
        XCTAssertEqual(result.count, 5)
    }

    func testASlowDiskDoesNotHoldUpLaunch() async throws {
        let system = try await fileSystem()
        await system.setLatency(nanoseconds: 20_000_000_000)
        let projects = home.appendingPathComponent("Projects", isDirectory: true)
        let started = Date()
        let result = await RestoredFolders.availability(of: [projects], fileSystem: system, home: home, deadline: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(result[projects], true)
    }

    func testNothingToCheck() async {
        let result = await RestoredFolders.availability(of: [], fileSystem: InMemoryFileSystem(), home: home)
        XCTAssertTrue(result.isEmpty)
    }
}
