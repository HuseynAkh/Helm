// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Supported M22 formats extend delegated F-007; DMG is a mount operation, never extraction.
public enum ArchiveFormat: String, CaseIterable, Sendable {
    case zip, tar, tarGzip = "tar.gz", tgz, tarBzip2 = "tar.bz2", gzip = "gz", diskImage = "dmg"
    public static func detect(_ name: String) throws -> ArchiveFormat {
        let lower = name.lowercased()
        for format in [ArchiveFormat.tarGzip, .tarBzip2, .zip, .tar, .tgz, .gzip, .diskImage] {
            if lower.hasSuffix("." + format.rawValue) { return format }
        }
        throw ArchivePlanningError.unsupportedFormat((name as NSString).pathExtension.lowercased())
    }
}

/// Staged M22 operation draft (F-059). Adapter reserves a fresh staging directory exclusively,
/// pins the inspected source, enforces limits, then journals a no-overwrite move to finalOutput.
public struct ArchivePlan: Equatable, Sendable {
    public let command: ArchiveCommand
    public let stagedOutput: URL
    public let finalOutput: URL
    public let safetyLimits: ArchiveSafetyLimits?
    public var expectedOutputName: String { finalOutput.lastPathComponent }
    public init(command: ArchiveCommand, stagedOutput: URL, finalOutput: URL, safetyLimits: ArchiveSafetyLimits? = nil) {
        self.command = command; self.stagedOutput = stagedOutput; self.finalOutput = finalOutput; self.safetyLimits = safetyLimits
    }
}

/// Pure M22 naming/command planning uses F-052 numeric suffixes (B-039/B-116), never executes I/O.
public enum ArchivePlanner {
    static func validFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true)
    }
    static func validatePaths(_ urls: [URL]) throws {
        guard urls.allSatisfy({ validFileURL($0) && $0.path.hasPrefix("/") && !$0.path.contains("\0") && $0.path != "/" }) else {
            throw ArchivePlanningError.invalidPath
        }
    }
    private static func validateStage(_ stage: URL, sources: [URL], destination: URL) throws {
        try validatePaths([stage])
        let path = stage.standardizedFileURL.path
        let forbidden = sources + [destination]
        guard !forbidden.contains(where: {
            let other = $0.standardizedFileURL.path
            return path == other || path.hasPrefix(other + "/") || other.hasPrefix(path + "/")
        }) else { throw ArchivePlanningError.invalidStagingDirectory }
    }
    public static func compress(items: [URL], stagingDirectory: URL, existingNames: Set<String> = [], caseSensitive: Bool = false) throws -> ArchivePlan {
        guard let first = items.first else { throw ArchivePlanningError.emptySelection }
        try validatePaths(items)
        let parent = first.standardizedFileURL.deletingLastPathComponent()
        guard items.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent() == parent }) else { throw ArchivePlanningError.differentParents }
        let uniqueItems = Array(Set(items.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        let raw = uniqueItems.count == 1 ? first.lastPathComponent + ".zip" : "Archive.zip"
        let name = try UniqueNamer.name(for: raw, existingNames: existingNames, caseSensitive: caseSensitive).value
        let output = parent.appendingPathComponent(name)
        try validateStage(stagingDirectory, sources: uniqueItems, destination: output)
        let staged = stagingDirectory.appendingPathComponent("output.zip")
        let command = ArchiveCommand(executablePath: "/usr/bin/zip",
            arguments: ["-r", "-y", staged.path, "--"] + uniqueItems.map { "./" + $0.lastPathComponent }, workingDirectory: parent)
        return ArchivePlan(command: command, stagedOutput: staged, finalOutput: output)
    }
    public static func uncompress(archive: URL, destinationDirectory: URL, stagingDirectory: URL,
                                  members: [ArchiveMember], existingNames: Set<String> = [],
                                  limits: ArchiveSafetyLimits = ArchiveSafetyLimits(), caseSensitive: Bool = false) throws -> ArchivePlan {
        try validatePaths([archive])
        guard validFileURL(destinationDirectory) else { throw ArchivePlanningError.invalidPath }
        let format = try ArchiveFormat.detect(archive.lastPathComponent)
        guard format != .diskImage else { throw ArchivePlanningError.mountDiskImageInstead }
        try ArchiveSafety.validate(members, limits: limits, caseSensitive: caseSensitive)
        let stem = String(archive.lastPathComponent.dropLast(format.rawValue.count + 1))
        let name = try UniqueNamer.name(for: stem.isEmpty ? "Archive" : stem, existingNames: existingNames, caseSensitive: caseSensitive).value
        let output = destinationDirectory.appendingPathComponent(name)
        try validateStage(stagingDirectory, sources: [archive], destination: output)
        let staged = stagingDirectory.appendingPathComponent("output", isDirectory: format != .gzip)
        let command: ArchiveCommand
        switch format {
        case .zip:
            command = ArchiveCommand(executablePath: "/usr/bin/unzip", arguments: ["-q", archive.standardizedFileURL.path, "-d", staged.path],
                workingDirectory: stagingDirectory, requiresConfinedExtraction: true)
        case .gzip:
            command = ArchiveCommand(executablePath: "/usr/bin/gzip", arguments: ["-dc", archive.standardizedFileURL.path],
                workingDirectory: stagingDirectory, standardOutputFile: staged, requiresConfinedExtraction: true)
        default:
            command = ArchiveCommand(executablePath: "/usr/bin/tar", arguments: ["-xf", archive.standardizedFileURL.path, "-C", staged.path],
                workingDirectory: stagingDirectory, requiresConfinedExtraction: true)
        }
        return ArchivePlan(command: command, stagedOutput: staged, finalOutput: output, safetyLimits: limits)
    }
}
