// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Argument-array command draft for M22 (F-052/F-059); never shell-interpolates user paths.
/// Extraction requires an adapter that enforces confinement and runtime limits, not a plain Process wrapper.
public struct ArchiveCommand: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: URL
    public let standardOutputFile: URL?
    public let requiresConfinedExtraction: Bool
    public init(executablePath: String, arguments: [String], workingDirectory: URL,
                standardOutputFile: URL? = nil, requiresConfinedExtraction: Bool = false) {
        self.executablePath = executablePath; self.arguments = arguments; self.workingDirectory = workingDirectory
        self.standardOutputFile = standardOutputFile; self.requiresConfinedExtraction = requiresConfinedExtraction
    }
}

/// Captured process completion for F-059/M22; cancellation is distinct from a tool failure.
public struct ArchiveProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardError: String
    public let wasCancelled: Bool
    public let terminationSignal: Int32?
    public init(exitCode: Int32, standardError: String = "", wasCancelled: Bool = false, terminationSignal: Int32? = nil) {
        self.exitCode = exitCode; self.standardError = standardError
        self.wasCancelled = wasCancelled; self.terminationSignal = terminationSignal
    }
    public func validate() throws {
        if wasCancelled { throw ArchivePlanningError.cancelled }
        if let signal = terminationSignal { throw ArchivePlanningError.terminated(signal) }
        guard exitCode == 0 else { throw ArchivePlanningError.toolFailed(code: exitCode, diagnostic: standardError) }
    }
}

/// Injected M22 process boundary (F-059). Live implementations must enforce plan staging and cancellation.
public protocol ProcessRunning: Sendable {
    func run(_ command: ArchiveCommand) async throws -> ArchiveProcessResult
}

/// Finite recorded process fixture for M22/F-059; executes no processes or filesystem writes.
public actor ScriptedProcessRunner: ProcessRunning {
    public private(set) var commands: [ArchiveCommand] = []
    private var results: [ArchiveProcessResult]
    public init(results: [ArchiveProcessResult]) { self.results = results }
    public func run(_ command: ArchiveCommand) async throws -> ArchiveProcessResult {
        if Task.isCancelled { throw ArchivePlanningError.cancelled }
        guard !results.isEmpty else { throw ArchivePlanningError.noScriptedResult }
        commands.append(command)
        return results.removeFirst()
    }
}

/// Typed M22 errors extend F-059 without treating failed or incomplete extraction as success.
public enum ArchivePlanningError: Error, Equatable, Sendable {
    case invalidPath, emptySelection, differentParents, invalidStagingDirectory
    case unsupportedFormat(String), mountDiskImageInstead
    case unsafeMember(String), duplicateMember(String), invalidLimits, expansionLimit, ratioLimit
    case cancelled, terminated(Int32), toolFailed(code: Int32, diagnostic: String), noScriptedResult
}
