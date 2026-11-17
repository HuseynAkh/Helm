import Foundation

/// Whether a typed message asks for changes, read from its words alone: "Can you organize them properly?" does,
/// "What's in here?" doesn't. A message that does is answered with a plan; when a model answers it with words
/// alone, the session asks once more for the plan (`AgentPrompt.planNow`).
public enum AgentChangeAsk {
    public static func asksForChanges(_ text: String) -> Bool {
        let words = text.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : ""
            if verbs.contains(word) {
                // "What sort of files are here?" asks nothing.
                if word == "sort", next == "of" { continue }
                return true
            }
            // "Draft a letter" asks for one; "the draft is old" doesn't.
            if word == "draft", determiners.contains(next) { return true }
            if word == "new", things.contains(next) { return true }
            let soon = words[(index + 1)...].prefix(4)
            if makers.contains(word), soon.contains(where: { folders.contains($0) || things.contains($0) }) { return true }
        }
        return false
    }

    /// Words that ask for a change wherever they are in a message.
    private static let verbs: Set<String> = [
        "organize", "organise", "reorganize", "reorganise", "sort", "tidy", "declutter", "clean", "arrange", "group",
        "gather", "move", "copy", "duplicate", "rename", "trash", "delete", "remove", "put", "flatten", "merge",
        "create", "write",
    ]
    /// "Make a folder for the photos" or "make a packing list" asks for a change; "make sense of this" doesn't.
    private static let makers: Set<String> = ["make", "add"]
    private static let folders: Set<String> = ["folder", "folders", "subfolder", "subfolders"]
    /// What a new file can be called in a request: "a new note", "make a list".
    private static let things: Set<String> = [
        "file", "files", "document", "documents", "doc", "docs", "note", "notes", "list", "page", "readme", "spreadsheet",
    ]
    private static let determiners: Set<String> = ["a", "an", "the", "me", "my", "some", "up"]
}
