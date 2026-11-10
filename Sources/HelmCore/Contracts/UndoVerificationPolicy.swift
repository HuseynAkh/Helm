import Foundation

/// How an inverse plan proves it still holds the items it is about to move (F-059, O1-1).
public enum UndoVerificationPolicy: Sendable, Equatable {
    case none
    /// Refuses directories and packages, and refuses any leaf whose metadata changed. For callers that
    /// must not act on edited content.
    case leafOnly
    /// What undo uses: the same object (volume and file number) must still be there. Changed contents don't
    /// refuse it, because an inverse only moves things back or to the Trash and destroys nothing. Finder
    /// allows the same, including for folders.
    case sameObject
}
