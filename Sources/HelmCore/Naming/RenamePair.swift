import Foundation

/// Validated F-054/F-055 request; source URL disambiguates equal names in Recent (B-047).
public struct RenamePair: Hashable, Sendable {
    public let source: URL
    public let newName: ValidFileName
    public init(source: URL, newName: ValidFileName) { self.source = source; self.newName = newName }
}

/// F-055 preview includes invalid proposals so the UI can explain them (B-046).
public struct RenamePreview: Equatable, Sendable {
    public let source: URL
    public let proposedName: String
    public init(source: URL, proposedName: String) { self.source = source; self.proposedName = proposedName }
}

/// Blocking F-055 failures; no executable steps are returned when any exist (B-047).
public enum BatchRenameIssue: Equatable, Sendable {
    case invalidName(URL, FileNameError)
    case counterOverflow(URL)
    case duplicateSource(URL)
    case collision(URL)
}

/// Preview and two-phase ordering for F-055 swaps (B-047).
/// Execution must recheck occupancy, stop on failure and journal temporary moves for rollback.
public struct BatchRenamePlan: Sendable {
    public let previews: [RenamePreview]
    public let renames: [RenamePair]
    public let steps: [RenamePair]
    public let issues: [BatchRenameIssue]
    public var hasChanges: Bool { !renames.isEmpty }
    public var canExecute: Bool { issues.isEmpty && hasChanges }
    public init(previews: [RenamePreview], renames: [RenamePair], steps: [RenamePair], issues: [BatchRenameIssue]) {
        self.previews = previews; self.renames = renames; self.steps = steps; self.issues = issues
    }
}
