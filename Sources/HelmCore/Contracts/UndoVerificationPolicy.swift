// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Conservative automatic undo policy preserves F-059 and prevents B-041 descendant loss.
/// Metadata cannot verify a whole tree: leafOnly refuses directories/packages even unchanged.
/// This is not a complete content/identity manifest or an atomic compare-and-mutate guarantee.
public enum UndoVerificationPolicy: Sendable, Equatable {
    case none
    case leafOnly
}
