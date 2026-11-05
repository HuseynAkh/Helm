// DRAFT: pending Opus review.
import Foundation

/// Shared lexical admission preserves local-only search and cloud actions (F-044, F-049).
/// Uses the F-012/F-063 parser without resolving symlinks or interpreting parent components.
public enum LocalFileURLAdmission {
    public static func accepts(_ url: URL) -> Bool { LexicalLocalPath(url) != nil }
}
