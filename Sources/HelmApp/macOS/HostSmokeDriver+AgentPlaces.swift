#if os(macOS)
import AppKit
import HelmCore
import HelmFileSystem
import HelmUI

/// Smoke verbs that stand in for where a folder is: cloud and server places, files not downloaded,
/// slow places and places with no Trash. They change only stand-ins, and only for folders in the fixture home.
extension HostSmokeDriver {
    static func performAgentPlacesVerb(_ verb: String, _ argument: String, step: String,
                                       window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "agent-place":
            // "<kind>[,shared][,notrash][,readonly][,silent]=<path>": the folder and everything in it answer as that
            // kind of place. "silent" is a place that didn't answer in time.
            guard let equals = argument.firstIndex(of: "=") else { check(false, step, "usage"); return true }
            let words = argument[..<equals].split(separator: ",").map(String.init)
            let path = String(argument[argument.index(after: equals)...])
            guard let kind = words.first.flatMap(StorageKind.init(rawValue:)),
                  Set(words.dropFirst()).isSubset(of: ["shared", "notrash", "readonly", "silent"]) else {
                check(false, step, "usage"); return true
            }
            guard let folder = fixtureFolder(path, window, app) else { check(false, step, "not in the fixture home"); return true }
            guard let reader = app.agentServicesForTesting?.storage as? MemoryStorageFactsReader else {
                check(false, step, "no stand-in for place facts"); return true
            }
            let flags = Set(words.dropFirst())
            reader.set(probe(for: kind, at: folder, flags: flags), under: folder)
            // A cloud folder is one place throughout, as a provider's folder is, so the folders in it are moved
            // between without leaving it.
            if kind == .cloud { reader.setMirror(target: folder, cloudFolder: "Cloud") }
            check(true, step)
        case "agent-cloud-only", "agent-not-loaded":
            guard let folder = fixtureFolder(argument, window, app) else { check(false, step, "not in the fixture home"); return true }
            guard let disk = app.agentServicesForTesting?.disk as? InjectedAgentDisk else {
                check(false, step, "no stand-in disk"); return true
            }
            if verb == "agent-cloud-only" { disk.markCloudOnly(folder) } else { disk.markNotLoaded(folder) }
            check(true, step)
        case "agent-delay":
            // "<seconds> <path>": every question about the path's place takes that long.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2, let seconds = Double(bits[0]), seconds >= 0 else { check(false, step, "usage"); return true }
            guard let folder = fixtureFolder(bits[1], window, app) else { check(false, step, "not in the fixture home"); return true }
            guard let disk = app.agentServicesForTesting?.disk as? InjectedAgentDisk else {
                check(false, step, "no stand-in disk"); return true
            }
            disk.setDelay(seconds, under: folder)
            check(true, step)
        case "agent-no-trash":
            guard let folder = fixtureFolder(argument, window, app) else { check(false, step, "not in the fixture home"); return true }
            app.fixtureTrashRules.refuse(under: folder)
            check(true, step)
        case "agent-places-clear":
            // Puts every stand-in above back as it was, so the step files after these see the fixture as it is.
            guard app.options.isIsolated else { check(false, step, "not a fixture run"); return true }
            (app.agentServicesForTesting?.storage as? MemoryStorageFactsReader)?.clear()
            (app.agentServicesForTesting?.disk as? InjectedAgentDisk)?.clear()
            app.fixtureTrashRules.clear()
            check(true, step)
        default:
            return false
        }
        return true
    }

    /// The raw facts a place of that kind gives. A server and an external disk are mounted at the folder itself,
    /// so they are places of their own apart from the home folder's disk.
    private static func probe(for kind: StorageKind, at folder: String, flags: Set<String>) -> StorageProbe {
        var probe: StorageProbe
        switch kind {
        case .thisMac: probe = StorageProbe(isLocal: true, isInternal: true, isRemovable: false, isEjectable: false)
        case .iCloud: probe = StorageProbe(isLocal: true, isInternal: true, isUbiquitous: true)
        case .cloud: probe = StorageProbe(isLocal: true, isInternal: true)
        case .network: probe = StorageProbe(isLocal: false, volumeRoot: folder)
        case .external: probe = StorageProbe(isLocal: true, isInternal: false, isRemovable: true, isEjectable: true, volumeRoot: folder)
        }
        if flags.contains("shared") { probe.isShared = true }
        if flags.contains("notrash") { probe.hasTrash = false }
        if flags.contains("readonly") { probe.isReadOnly = true }
        if flags.contains("silent") { probe.timedOut = true }
        return probe
    }

    /// The folder's path as the disk spells it, when the run is a fixture run and the folder is in its home folder;
    /// nil otherwise, so these verbs can never make a real folder look different.
    private static func fixtureFolder(_ path: String, _ window: BrowserWindowController, _ app: AppController) -> String? {
        guard app.options.isIsolated, path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              window.dependencies.home.path.contains("/.build/host-smoke/fixture/home") else { return nil }
        let home = CanonicalPath.realPath(window.dependencies.home.path) ?? window.dependencies.home.path
        let spelled = CanonicalPath.realPath(path) ?? URL(fileURLWithPath: path).standardizedFileURL.path
        let inside = spelled.hasPrefix(home + "/") || spelled == home
        return inside ? spelled : nil
    }
}
#endif
