// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// File commands preserve F-052–F-057; destructive deletion is intentionally absent (B-041).
public enum Command: Hashable, Sendable {
    case copy(sources: [URL], destinationDirectory: URL)
    case move(sources: [URL], destinationDirectory: URL)
    case duplicate(sources: [URL])
    case trash(items: [URL])
    case rename(RenamePair), batchRename([RenamePair])
    case createFolder(parent: URL, name: ValidFileName)
    case createFile(parent: URL, name: ValidFileName, template: URL?)
    case recovery
}
/// F-052 conflict decisions; replacing a directory never means merging it.
public enum ConflictResolution: String, Hashable, Sendable { case keepBoth, replace, skip, stop }
/// Per-item decisions or one retained apply-to-all choice (F-052).
public struct ConflictPolicy: Hashable, Sendable {
    public var defaultResolution: ConflictResolution
    public var perItem: [URL: ConflictResolution]
    public var applyToAll: Bool
    public init(defaultResolution: ConflictResolution = .keepBoth, perItem: [URL: ConflictResolution] = [:], applyToAll: Bool = false) {
        self.defaultResolution = defaultResolution; self.perItem = perItem; self.applyToAll = applyToAll
    }
    public func resolution(for source: URL) -> ConflictResolution {
        applyToAll ? defaultResolution : perItem[source] ?? defaultResolution
    }
}
/// Exact conflicting paths used by the F-052 conflict sheet.
public struct Conflict: Hashable, Sendable {
    public let source: URL?
    public let destination: URL
    public init(source: URL?, destination: URL) { self.source = source; self.destination = destination }
}
/// Explicit preflight diagnostics replace silent wrong-target operations (B-031/B-040/B-047).
public enum PlanningIssue: Hashable, Sendable {
    case virtualLocationTarget, invalidURL(URL), missingSnapshot(URL), overlappingSelection(URL)
    case destinationInsideSource(URL), sourceEqualsDestination(URL), collision(URL), stopped
    case sameParentMove(URL), invalidName, insufficientSpace(URL)
    public var isBlocking: Bool {
        if case .sameParentMove = self { return false }
        return true
    }
}
/// Sequential mutation primitives retain exact temporary rename paths (F-055/B-038).
public struct PlannedStep: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable { case copy, move, trash, createDirectory, createFile, verifyCopy }
    public let id: StepID
    public let kind: Kind
    public let source: URL?
    public let destination: URL?
    public let contents: Data
    public let retryKeepBoth: Bool
    public let collisionName: String?
    public let verificationDestination: URL?
    public init(id: StepID = StepID(), kind: Kind, source: URL? = nil, destination: URL? = nil,
                contents: Data = Data(), retryKeepBoth: Bool = false, collisionName: String? = nil, verificationDestination: URL? = nil) {
        self.id = id; self.kind = kind; self.source = source; self.destination = destination
        self.contents = contents; self.retryKeepBoth = retryKeepBoth; self.collisionName = collisionName; self.verificationDestination = verificationDestination
    }
}
/// Immutable executable plan preserves exact source/destination pairing (B-042).
public struct OperationPlan: Sendable {
    public let command: Command
    public let steps: [PlannedStep]
    public let issues: [PlanningIssue]
    public let context: PlanningContext
    public let undoVerification: UndoVerificationPolicy
    public let expectedKinds: [URL: FileEntryKind]
    /// Recorded output ownership for safe leaf undo (B-041); never inferred from the current occupant.
    public let expectedEvidence: [URL: FileMutationPrecondition]
    public let expectedTokens: [URL: ChangeToken]
    public var isExecutable: Bool { !issues.contains(where: \.isBlocking) }
    public init(command: Command, steps: [PlannedStep], issues: [PlanningIssue] = [], context: PlanningContext = PlanningContext(), expectedTokens: [URL: ChangeToken] = [:],
                undoVerification: UndoVerificationPolicy = .none, expectedKinds: [URL: FileEntryKind] = [:], expectedEvidence: [URL: FileMutationPrecondition] = [:]) {
        self.expectedEvidence = expectedEvidence
        self.undoVerification = undoVerification; self.expectedKinds = expectedKinds
        self.command = command; self.steps = steps; self.issues = issues; self.context = context; self.expectedTokens = expectedTokens
    }
}
