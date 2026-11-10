// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmFileSystem

/// F-052 baseline verifies no-follow tree shape, kinds and sizes, not byte hashes or metadata fidelity.
/// Executor also requires the planning manifest's source tokens to remain unchanged before retirement.
public struct TreeCopyVerifier: CopyVerifying {
    private let fileSystem: any FileSystem
    public init(fileSystem: any FileSystem) { self.fileSystem = fileSystem }
    public func verify(source: URL, destination: URL) async throws {
        let sourceTree = try await tree(source)
        let destinationTree = try await tree(destination)
        guard sourceTree == destinationTree else { throw OperationError.verificationFailed }
    }
    private struct Signature: Equatable { let kind: FileEntryKind; let size: Int64 }
    private func tree(_ root: URL) async throws -> [String: Signature] {
        var result: [String: Signature] = [:]
        var pending: [(URL, String)] = [(root, "")]
        while let (url, relative) = pending.popLast() {
            try Task.checkCancellation()
            let entry = try await fileSystem.entry(at: url)
            let directory = entry.kind == .directory || entry.kind == .package
            // Link size is platform-specific, but mismatched kinds remain a verification failure.
            result[relative] = Signature(kind: entry.kind, size: directory ? 0 : entry.size)
            if directory {
                for try await batch in fileSystem.enumerate(url, options: EnumerationOptions(includeHidden: true, resolveSymlinkTargets: false)) {
                    pending += batch.map { ($0.url, relative + "/" + $0.name) }
                }
            }
        }
        return result
    }
}
