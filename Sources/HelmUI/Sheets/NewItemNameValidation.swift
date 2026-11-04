// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import HelmCore

/// Shared creation/rename messages preserve F-054–F-057 while rejecting traversal (B-046).
/// Occupancy and template eligibility remain the planner's responsibility.
public enum NewItemNameValidation {
    public static func message(for error: FileNameError) -> String {
        switch error {
        case .empty: return "Enter a name."
        case .separator: return "The name cannot contain a slash (/)."
        case .nul: return "The name cannot contain a null character."
        case .dot: return "The name cannot be “.” or “..”."
        case .tooLong: return "The name is too long (maximum 255 UTF-8 bytes)."
        }
    }
    public static func message(for rawName: String) -> String? {
        switch FileNameValidator.validate(rawName) {
        case .success: return nil
        case .failure(let error): return message(for: error)
        }
    }
}
