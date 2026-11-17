import Foundation
import HelmCore

/// The one rule for names a model writes: new folders, new files and renames. It is the same in every place, so a
/// name that works on this Mac also works in any cloud folder and on a server. On top of it, a plan can't make
/// something that runs: a renamed file keeps its extension, a folder can't take on one, a new file ends in one of a
/// few text and document extensions, and no file is given a name that runs on a double click elsewhere or when
/// someone runs a routine command in its folder.
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
    /// change one, add one or remove one. A change of case alone passes. Nor can a rename give a file a refused name
    /// (`isRefusedFileName`), so a file a plan made can't become one later.
    public static func validateFileRename(_ text: String, from old: String) -> Result<ValidFileName, AgentToolCode> {
        validate(text).flatMap { name in
            fileExtension(of: name.value) == fileExtension(of: old) && !isRefusedFileName(name.value)
                ? .success(name) : .failure(.name_not_allowed)
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

    /// The shared rule, and the name ends in an extension a new file may have (`isNewFileExtension`) and isn't
    /// refused (`isRefusedFileName`). A hidden name, with a leading dot, already fails the shared rule.
    public static func validateNewFileName(_ text: String) -> Result<ValidFileName, AgentToolCode> {
        validate(text).flatMap { name in
            isNewFileExtension(fileExtension(of: name.value)) && !isRefusedFileName(name.value)
                ? .success(name) : .failure(.name_not_allowed)
        }
    }

    /// Whether a new file may end in `ext`: a document, or another text or code kind of `AISearchKind`'s table that
    /// doesn't run on a double click on Windows. Nothing that runs on a double click on a Mac, opens an address,
    /// installs something or is an app is among them.
    public static func isNewFileExtension(_ ext: String?) -> Bool {
        guard let ext else { return false }
        if newFileDocuments.contains(ext) { return true }
        if refusedExtensions.contains(ext) { return false }
        let kind = AISearchKind.of(typeIdentifier: nil, extension: ext, kind: .regular)
        return kind == .text || kind == .code
    }

    /// Whether a new file of this name is code or a web page, whose group starts unticked: any extension a new file
    /// may have but a document's.
    public static func isNewFileCode(_ name: String) -> Bool {
        fileExtension(of: name).map { !newFileDocuments.contains($0) } ?? true
    }

    /// Whether a file may never have this name, in any case: one that runs when someone runs a routine command in its
    /// folder (a test run, an install, a build), one Windows reads on its own when it opens the folder or the disk,
    /// or one Windows keeps for a device, whatever comes after its first dot.
    public static func isRefusedFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if refusedNames.contains(lower) || refusedEndings.contains(where: { lower.hasSuffix($0) }) { return true }
        // Windows drops the spaces before the dot, so "con .txt" is the device too.
        return reservedStems.contains(lower.prefix { $0 != "." }.trimmingCharacters(in: .whitespaces))
    }

    // MARK: The new-file tables

    /// Documents: a new file of one of these starts ticked. RTF and Word are made from the text.
    private static let newFileDocuments: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "rtf", "docx", "log",
    ]
    /// Code kinds that run on a double click on Windows. Other JavaScript (mjs, cjs, ts) stays, as code.
    private static let refusedExtensions: Set<String> = ["bat", "cmd", "ps1", "vbs", "vbe", "wsf", "wsh", "hta", "js"]
    /// Whole names, in lower case, that run on a routine command or that Windows reads on its own.
    private static let refusedNames: Set<String> = [
        "conftest.py", "setup.py", "sitecustomize.py", "usercustomize.py", "package.json", "pyproject.toml", "setup.cfg",
        "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "cmakelists.txt",
        "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", "desktop.ini", "autorun.inf",
    ]
    /// Endings of a tool's settings that are code it runs, such as "vite.config.ts".
    private static let refusedEndings = [".config.js", ".config.mjs", ".config.cjs", ".config.ts"]
    /// The names Windows keeps for devices.
    private static let reservedStems: Set<String> = Set(["con", "prn", "aux", "nul"]
        + (1...9).flatMap { ["com\($0)", "lpt\($0)"] })

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
