import Foundation
import HelmCore

/// The one rule for names a model writes: new folders and renames. It is the same in every place, so a name that
/// works on this Mac also works in any cloud folder and on a server. On top of it, a plan can't make something that
/// runs: a renamed file keeps its extension, and a folder can't take on one.
public enum AgentNewName {
    /// Characters that some place Helm can work in won't hold in a name.
    private static let refusedCharacters: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\0"]
    /// The longest extension, in characters.
    private static let longestExtension = 16
    private static let maximumBytes = 255

    /// The shared name rule: one path component; not empty, `.` or `..`; none of `/ \ : * ? " < > |` or NUL; nothing
    /// the escaper would show as an escape; no leading dot, space or `~`; no trailing dot or space; 255 UTF-8 bytes at
    /// most; and a valid file name as the rest of Helm reads one.
    public static func validate(_ text: String) -> Result<ValidFileName, AgentToolCode> {
        guard !text.isEmpty, text != ".", text != "..", text.utf8.count <= maximumBytes,
              !text.contains(where: refusedCharacters.contains),
              AgentTextEscaper.isClean(text),
              let first = text.first, let last = text.last,
              first != ".", first != "~", !isSpace(first), last != ".", !isSpace(last),
              let name = ValidFileName(text), name.value == text else {
            return .failure(.name_not_allowed)
        }
        return .success(name)
    }

    /// The shared rule, and the file's extension stays exactly as it was, without regard to case: a rename can't
    /// change one, add one or remove one. A change of case alone passes.
    public static func validateFileRename(_ text: String, from old: String) -> Result<ValidFileName, AgentToolCode> {
        validate(text).flatMap { name in
            fileExtension(of: name.value) == fileExtension(of: old) ? .success(name) : .failure(.name_not_allowed)
        }
    }

    /// The shared rule, and the name may end in an extension only if `old`, the folder's name now, ends in the same
    /// one. A new folder has no old name, so its name can't end in an extension at all.
    public static func validateFolderName(_ text: String, existing old: String?) -> Result<ValidFileName, AgentToolCode> {
        validate(text).flatMap { name in
            guard let added = fileExtension(of: name.value) else { return .success(name) }
            return old.flatMap(fileExtension(of:)) == added ? .success(name) : .failure(.name_not_allowed)
        }
    }

    /// The text after the last dot, lower-cased, when it is 1 to 16 letters and digits with at least one letter.
    /// So "Invoice.app" has the extension "app", and "2026.03" and "v1.2" have none.
    public static func fileExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let tail = name[name.index(after: dot)...]
        let scalars = tail.unicodeScalars
        guard (1...longestExtension).contains(tail.count),
              scalars.allSatisfy({ CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }),
              scalars.contains(where: CharacterSet.letters.contains) else { return nil }
        return tail.lowercased()
    }

    /// The form two names are compared in: without regard to case or to the form accents are written in. Two names
    /// in one folder with the same key clash, whatever the disk under them would say.
    public static func clashKey(_ name: String) -> String {
        FileNameComparison.key(name, caseSensitive: false)
    }

    private static func isSpace(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
