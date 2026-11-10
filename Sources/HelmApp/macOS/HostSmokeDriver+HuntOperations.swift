#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for the file-operations checks. Every write stays inside the fixture run's own home folder.
extension HostSmokeDriver {
    static func performHuntOperationsVerb(_ verb: String, _ argument: String, step: String,
                                          window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "hunt-op-status":
            // hunt-op-status <words>: some row in the operations panel says these words.
            let rows = window.dependencies.operations.currentRows.map { "\($0.title) | \($0.status)" }
            check(rows.contains { $0.contains(argument) }, step, rows.isEmpty ? "no rows" : rows.joined(separator: " ; "))
        case "hunt-cmd-says":
            // hunt-cmd-says <command> <words>: the command, then a message saying these words within a second and a half.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2, let command = CommandID(rawValue: bits[0]) else { check(false, step, "usage"); return true }
            var said: [String] = []
            window.messageObserver = { message in said.append(message); print("MSG \(message)"); fflush(stdout) }
            window.perform(command)
            for _ in 0..<15 where !said.contains(where: { $0.contains(bits[1]) }) { await wait(seconds: 0.1) }
            check(said.contains { $0.contains(bits[1]) }, step, said.isEmpty ? "nothing said" : said.joined(separator: " ; "))
        case "hunt-make-app":
            // hunt-make-app <path ending in .app>: a minimal app bundle inside the fixture home, which macOS treats as a package.
            guard argument.hasSuffix(".app"), isFixturePath(argument, window: window) else {
                check(false, step, "refused: not a fixture .app path"); return true
            }
            let contents = URL(fileURLWithPath: argument, isDirectory: true).appendingPathComponent("Contents", isDirectory: true)
            try? FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let name = URL(fileURLWithPath: argument).deletingPathExtension().lastPathComponent
            let plist: [String: Any] = ["CFBundleName": name, "CFBundleIdentifier": "com.example.hunt.\(name.lowercased())",
                                        "CFBundlePackageType": "APPL", "CFBundleExecutable": name]
            let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            FileManager.default.createFile(atPath: contents.appendingPathComponent("Info.plist").path, contents: data)
            check(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Info.plist").path), step)
        default:
            return false
        }
        return true
    }

    private static func isFixturePath(_ path: String, window: BrowserWindowController) -> Bool {
        PathSpelling.standardPath(URL(fileURLWithPath: path)).hasPrefix(PathSpelling.standardPath(window.dependencies.home) + "/")
    }
}
#endif
