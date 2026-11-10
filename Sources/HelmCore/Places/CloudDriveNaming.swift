import Foundation

/// Names for the cloud drives macOS keeps under `~/Library/CloudStorage`, whose folders read `GoogleDrive-me@example.com`.
public enum CloudDriveNaming {
    /// The provider's name, spaced out. Folder names are `Provider-Account` or just `Provider`.
    public static func provider(ofFolder folder: String) -> String {
        let base = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
        var result = ""
        var previousWasLower = false
        for character in base {
            if character.isUppercase, previousWasLower { result.append(" ") }
            result.append(character)
            previousWasLower = character.isLowercase
        }
        // Brand names keep their one-word spelling.
        return ["One Drive": "OneDrive", "Drop Box": "Dropbox", "Next Cloud": "Nextcloud"][result] ?? result
    }
    /// One name per folder. Two accounts with one provider also show the account, so they can be told apart.
    public static func names(forFolders folders: [String]) -> [String: String] {
        let counts = Dictionary(grouping: folders, by: provider(ofFolder:)).mapValues(\.count)
        var result: [String: String] = [:]
        for folder in folders {
            let name = provider(ofFolder: folder)
            let parts = folder.split(separator: "-", maxSplits: 1).map(String.init)
            result[folder] = (counts[name] ?? 0) > 1 && parts.count == 2 ? "\(name) (\(parts[1]))" : name
        }
        return result
    }
}
