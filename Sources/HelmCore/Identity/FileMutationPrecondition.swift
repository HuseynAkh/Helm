// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// No-follow provider identity for F-052/F-059 source checks (B-038/B-041).
/// Scope includes the provider/volume. Native inode observations can be recycled;
/// possession of this value alone never authorizes a non-atomic mutation.
public struct FileObjectIdentity: Hashable, Sendable, Codable {
    public let scope: String
    public let object: String
    public init(scope: String, object: String) { self.scope = scope; self.object = object }
}

/// Conditional source evidence for F-052/F-059. Root metadata is not descendant/content proof (B-041).
public struct FileMutationPrecondition: Hashable, Sendable {
    public let identity: FileObjectIdentity
    public let changeToken: ChangeToken
    public let kind: FileEntryKind
    public init(identity: FileObjectIdentity, changeToken: ChangeToken, kind: FileEntryKind) {
        self.identity = identity; self.changeToken = changeToken; self.kind = kind
    }
}

/// Exclusive mutations preserve F-052/F-053/F-059 and cannot replace an occupied destination (B-039).
public enum ConditionalFileMutation: Sendable { case copy(to: URL), move(to: URL), trash }

/// Refusals guarantee no mutation; uncertain native completion must use ordinary I/O errors (B-038).
public enum ConditionalMutationError: Error, Sendable, Equatable {
    case unsupported, sourceChanged
    /// Cancellation refused admission before any effect; ordinary CancellationError remains uncertain.
    case cancelledBeforeMutation
}
