// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmFileSystem

/// F-052 copy seam; native metadata fidelity and byte cancellation remain a Mac handoff.
public protocol FileCopier: Sendable {
    func copy(from source: URL, to destination: URL) async throws
    func copy(from source: URL, to destination: URL, requiring precondition: FileMutationPrecondition) async throws
}
public extension FileCopier {
    /// Existing adapters compile but must opt into atomic source admission before executor use (B-038).
    func copy(from source: URL, to destination: URL, requiring precondition: FileMutationPrecondition) async throws {
        throw ConditionalMutationError.unsupported
    }
}
/// F-052 baseline delegates whole-tree copying to K5; no byte-level cancellation promise.
public struct FoundationFileCopier: FileCopier {
    private let fileSystem: any FileSystem
    public init(fileSystem: any FileSystem) { self.fileSystem = fileSystem }
    public func copy(from source: URL, to destination: URL) async throws { try await fileSystem.copyItem(at: source, to: destination) }
    public func copy(from source: URL, to destination: URL, requiring precondition: FileMutationPrecondition) async throws {
        _ = try await fileSystem.mutate(.copy(to: destination), source: source, requiring: precondition)
    }
}
/// Must verify copy completeness AND unchanged source before retirement (F-052/B-038).
public protocol CopyVerifying: Sendable { func verify(source: URL, destination: URL) async throws }
/// Fail closed until a content-aware verifier is supplied; size alone is insufficient (B-038).
public struct UnavailableCopyVerifier: CopyVerifying {
    public init() {}
    public func verify(source: URL, destination: URL) async throws { throw OperationError.verificationUnavailable }
}

/// Adapter guarantee that an exclusive destination collision caused NO mutation (F-052/B-039).
/// Never translate generic I/O failures into this value; partial copies must not be retried.
public struct ExclusiveDestinationConflict: Error, Sendable {
    public init() {}
}
