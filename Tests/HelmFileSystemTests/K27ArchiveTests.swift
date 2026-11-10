// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmFileSystem

final class K27ArchiveTests: XCTestCase {
    private let stage = URL(fileURLWithPath: "/staging/owned-token")
    private let folder = URL(fileURLWithPath: "/files")
    private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
    private func member(_ path: String, kind: ArchiveMember.Kind = .file, size: UInt64 = 10, packed: UInt64 = 5) -> ArchiveMember {
        ArchiveMember(path: path, kind: kind, expandedBytes: size, compressedBytes: packed)
    }
    func testCompressionNamingAndArgumentBoundaries() throws {
        let plan = try ArchivePlanner.compress(items: [file("a.txt")], stagingDirectory: stage, existingNames: ["A.txt.zip", "a.txt 2.zip"])
        XCTAssertEqual(plan.expectedOutputName, "a.txt 3.zip")
        XCTAssertEqual(plan.command.executablePath, "/usr/bin/zip")
        XCTAssertEqual(plan.command.workingDirectory.path, folder.path)
        XCTAssertEqual(plan.command.arguments, ["-r", "-y", stage.appendingPathComponent("output.zip").path, "--", "./a.txt"])
        XCTAssertNotEqual(plan.stagedOutput, plan.finalOutput)
        let multi = try ArchivePlanner.compress(items: [file("-flag"), file("a $(touch x);.txt")], stagingDirectory: stage, existingNames: ["Archive.zip"])
        XCTAssertEqual(multi.expectedOutputName, "Archive 2.zip")
        XCTAssertEqual(Array(multi.command.arguments.suffix(2)), ["./-flag", "./a $(touch x);.txt"])
        let duplicate = try ArchivePlanner.compress(items: [file("a"), file("a")], stagingDirectory: stage)
        XCTAssertEqual(duplicate.expectedOutputName, "a.zip")
    }
    func testCompressionRejectsBadInputsAndUnsafeStage() throws {
        XCTAssertThrowsError(try ArchivePlanner.compress(items: [], stagingDirectory: stage))
        XCTAssertThrowsError(try ArchivePlanner.compress(items: [file("a"), URL(fileURLWithPath: "/other/b")], stagingDirectory: stage))
        for input in [URL(string: "https://host/a"), URL(string: "file://remote/a"), URL(fileURLWithPath: "/")] {
            if let input = input { XCTAssertThrowsError(try ArchivePlanner.compress(items: [input], stagingDirectory: stage)) }
        }
        for unsafe in [file("a"), file("a/subdirectory"), folder, file("a.zip")] {
            XCTAssertThrowsError(try ArchivePlanner.compress(items: [file("a")], stagingDirectory: unsafe))
        }
    }
    func testSupportedFormatsAndUnsupportedTypes() throws {
        let formats: [(String, ArchiveFormat)] = [("a.ZIP", .zip), ("a.tar", .tar), ("a.tar.gz", .tarGzip),
            ("a.tgz", .tgz), ("a.tar.bz2", .tarBzip2), ("a.gz", .gzip), ("a.dmg", .diskImage)]
        for (name, format) in formats { XCTAssertEqual(try ArchiveFormat.detect(name), format) }
        for ext in ["7z", "rar", "txt", ""] {
            XCTAssertThrowsError(try ArchiveFormat.detect("a." + ext)) { XCTAssertEqual($0 as? ArchivePlanningError, .unsupportedFormat(ext)) }
        }
        XCTAssertThrowsError(try ArchivePlanner.uncompress(archive: file("a.dmg"), destinationDirectory: folder, stagingDirectory: stage, members: [])) {
            XCTAssertEqual($0 as? ArchivePlanningError, .mountDiskImageInstead)
        }
    }
    func testExtractionPlansRequireConfinementAndStripCompoundSuffix() throws {
        for ext in ["zip", "tar", "tar.gz", "tgz", "tar.bz2", "gz"] {
            let plan = try ArchivePlanner.uncompress(archive: file("data." + ext), destinationDirectory: folder,
                stagingDirectory: stage, members: [member("data")], existingNames: ["data"])
            XCTAssertEqual(plan.expectedOutputName, "data 2")
            XCTAssertTrue(plan.command.requiresConfinedExtraction)
            XCTAssertEqual(plan.safetyLimits, ArchiveSafetyLimits())
            XCTAssertTrue(plan.command.arguments.contains(file("data." + ext).path))
            if ext == "gz" { XCTAssertEqual(plan.command.standardOutputFile, plan.stagedOutput) }
            else { XCTAssertNil(plan.command.standardOutputFile) }
        }
        XCTAssertThrowsError(try ArchivePlanner.uncompress(archive: file("a.zip"), destinationDirectory: folder,
            stagingDirectory: file("a/sub"), members: []))
        let web = try XCTUnwrap(URL(string: "https://host/out"))
        XCTAssertThrowsError(try ArchivePlanner.uncompress(archive: file("a.zip"), destinationDirectory: web,
            stagingDirectory: stage, members: []))
    }
    func testTraversalAndLinkRejection() {
        for path in ["../a", "a/../../b", "/absolute", "C:/windows", "a\\..\\b", "\\\\server\\x", "a\0b", "a\nb", "", ".", "./"] {
            XCTAssertThrowsError(try ArchiveSafety.validate([member(path)]), path)
        }
        for kind in [ArchiveMember.Kind.symbolicLink, .hardLink, .special] {
            XCTAssertThrowsError(try ArchiveSafety.validate([member("safe-looking", kind: kind)]))
        }
        XCTAssertNoThrow(try ArchiveSafety.validate([member("dir/", kind: .directory, size: 0, packed: 0), member("dir/file")]))
        // Percent sequences are literal archive names, not URL-decoded paths.
        XCTAssertNoThrow(try ArchiveSafety.validate([member("%2e%2e/literal")]))
    }
    func testDuplicateAndAncestorDestinations() {
        for paths in [["a", "./a"], ["a/b", "a//b"], ["A", "a"], ["café", "cafe\u{301}"]] {
            XCTAssertThrowsError(try ArchiveSafety.validate(paths.map { member($0) }))
        }
        XCTAssertNoThrow(try ArchiveSafety.validate([member("A"), member("a")], caseSensitive: true))
        XCTAssertThrowsError(try ArchiveSafety.validate([member("a"), member("a/b")]))
        XCTAssertThrowsError(try ArchiveSafety.validate([member("a/b"), member("a")]))
    }
    func testBombLimitsAndOverflow() {
        XCTAssertThrowsError(try ArchiveSafety.validate([member("a")], limits: ArchiveSafetyLimits(maximumMembers: 0)))
        XCTAssertThrowsError(try ArchiveSafety.validate([member("a"), member("b")], limits: ArchiveSafetyLimits(maximumExpandedBytes: 19)))
        XCTAssertThrowsError(try ArchiveSafety.validate([member("a", size: 11, packed: 1)], limits: ArchiveSafetyLimits(maximumRatio: 10)))
        XCTAssertThrowsError(try ArchiveSafety.validate([member("a", size: 1, packed: 0)]))
        XCTAssertThrowsError(try ArchiveSafety.validate([member("a", size: UInt64.max, packed: UInt64.max), member("b")], limits: ArchiveSafetyLimits(maximumExpandedBytes: UInt64.max)))
        for ratio in [Double.nan, .infinity, 0, -1] {
            XCTAssertThrowsError(try ArchiveSafety.validate([], limits: ArchiveSafetyLimits(maximumRatio: ratio)))
        }
        XCTAssertThrowsError(try ArchiveSafety.validate([], limits: ArchiveSafetyLimits(maximumMembers: -1)))
        XCTAssertNoThrow(try ArchiveSafety.validate([member("a", size: 20, packed: 2)], limits: ArchiveSafetyLimits(maximumMembers: 1, maximumExpandedBytes: 20, maximumRatio: 10)))
    }
    func testProcessCompletionErrors() {
        XCTAssertNoThrow(try ArchiveProcessResult(exitCode: 0).validate())
        for code: Int32 in [1, 2, 9, 127] {
            XCTAssertThrowsError(try ArchiveProcessResult(exitCode: code, standardError: "failed").validate()) {
                XCTAssertEqual($0 as? ArchivePlanningError, .toolFailed(code: code, diagnostic: "failed"))
            }
        }
        XCTAssertThrowsError(try ArchiveProcessResult(exitCode: 0, wasCancelled: true).validate()) { XCTAssertEqual($0 as? ArchivePlanningError, .cancelled) }
        XCTAssertThrowsError(try ArchiveProcessResult(exitCode: 0, terminationSignal: 15).validate()) { XCTAssertEqual($0 as? ArchivePlanningError, .terminated(15)) }
    }
    func testFakeRunnerRecordsAndExhaustsWithoutExecution() async throws {
        let plan = try ArchivePlanner.compress(items: [file("a")], stagingDirectory: stage)
        let runner = ScriptedProcessRunner(results: [ArchiveProcessResult(exitCode: 0), ArchiveProcessResult(exitCode: 2)])
        let first = try await runner.run(plan.command), second = try await runner.run(plan.command)
        XCTAssertEqual(first.exitCode, 0); XCTAssertEqual(second.exitCode, 2)
        let commands = await runner.commands
        XCTAssertEqual(commands, [plan.command, plan.command])
        do { _ = try await runner.run(plan.command); XCTFail("Expected exhausted fixture") }
        catch { XCTAssertEqual(error as? ArchivePlanningError, .noScriptedResult) }
    }
    func testCancelledFakeNeverConsumesResult() async throws {
        let runner = ScriptedProcessRunner(results: [ArchiveProcessResult(exitCode: 0)])
        let plan = try ArchivePlanner.compress(items: [file("a")], stagingDirectory: stage)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await runner.run(plan.command); XCTFail("Cancelled command ran") }
            catch { XCTAssertEqual(error as? ArchivePlanningError, .cancelled) }
        }
        await task.value
        let commands = await runner.commands
        XCTAssertTrue(commands.isEmpty)
        let result = try await runner.run(plan.command)
        XCTAssertEqual(result.exitCode, 0)
    }
    func testDiskImageArguments() throws {
        let plan = try DiskImagePlanner.attach(image: file("-image name.dmg"))
        XCTAssertEqual(plan.command.executablePath, "/usr/bin/hdiutil")
        XCTAssertEqual(plan.command.arguments, ["attach", "-plist", "-nobrowse", "-noautoopen", "-readonly", "/files/-image name.dmg"])
        XCTAssertFalse(try DiskImagePlanner.attach(image: file("a.iso"), readOnly: false).command.arguments.contains("-readonly"))
        XCTAssertThrowsError(try DiskImagePlanner.attach(image: file("a.zip")))
    }
    func testDiskImageResultParsing() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["system-entities": [
            ["dev-entry": "/dev/disk9"], ["mount-point": "/Volumes/A"], ["mount-point": "/Volumes/A"]]], format: .xml, options: 0)
        XCTAssertEqual(DiskImagePlanner.result(ArchiveProcessResult(exitCode: 0), propertyList: data), .mounted([URL(fileURLWithPath: "/Volumes/A")]))
        XCTAssertEqual(DiskImagePlanner.result(ArchiveProcessResult(exitCode: 0, wasCancelled: true), propertyList: data), .cancelled)
        XCTAssertEqual(DiskImagePlanner.result(ArchiveProcessResult(exitCode: 1, standardError: "bad"), propertyList: data), .failed(code: 1, diagnostic: "bad"))
        XCTAssertEqual(DiskImagePlanner.result(ArchiveProcessResult(exitCode: 0), propertyList: Data()), .invalidResponse)
        for entities in [[], [["mount-point": "relative"]], [["dev-entry": "/dev/disk9"]]] {
            let invalid = try PropertyListSerialization.data(fromPropertyList: ["system-entities": entities], format: .xml, options: 0)
            XCTAssertEqual(DiskImagePlanner.result(ArchiveProcessResult(exitCode: 0), propertyList: invalid), .invalidResponse)
        }
    }
}
