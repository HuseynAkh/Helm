#if os(macOS)
import AppKit
import HelmCore
import HelmFileSystem
import HelmOperations

/// File › Compress and Expand, done the way Finder does them.
extension BrowserWindowController {
    /// Archive Utility is what Finder uses to expand an archive: next to the archive, in a folder of its own
    /// when it holds more than one item, with its own progress and safety checks.
    static let archiveUtility = URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Archive Utility.app")
    static let expandableExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "cpio", "xar", "z"]

    static func isExpandable(_ url: URL) -> Bool { expandableExtensions.contains(url.pathExtension.lowercased()) }

    /// "Compress “Report.pdf”" or "Compress 3 Items", as in Finder.
    func compressTitle() -> String {
        let entries = selectedEntries()
        if entries.count == 1, let entry = entries.first { return "Compress “\(entry.name)”" }
        return entries.count > 1 ? "Compress \(entries.count) Items" : "Compress"
    }

    /// One item becomes "<name>.zip"; several become "Archive.zip". A taken name gets a number, as in Finder.
    /// The archive is written in a private folder on the same disk first, so a half-written one never appears.
    func compressSelection() {
        let urls = OperationPlanner.outermost(selectedEntries().map(\.url))
        guard activeTab?.location.mutationTarget != nil, let first = urls.first else { NSSound.beep(); return }
        // The archive goes next to the items, which inside an open folder in the list isn't the folder on show.
        let folder = first.deletingLastPathComponent()
        guard urls.allSatisfy({ Self.isSame($0.deletingLastPathComponent(), folder) }) else {
            show(message: "Items from different folders can’t go in one archive. Choose items from one folder.")
            return
        }
        let fileSystem = dependencies.fileSystem
        let tabID = activeTabID
        Task { @MainActor in
            let staging: URL
            let plan: ArchivePlan
            do {
                staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
                let names = try await fileSystem.childNames(of: folder)
                plan = try ArchivePlanner.compress(items: urls, stagingDirectory: staging, existingNames: names)
            } catch {
                show(message: "Couldn’t compress: \(Self.compressionProblem(error))"); return
            }
            // One item goes through ditto, which keeps extended attributes and resource forks just as Finder's
            // archives do. Several go through zip, which keeps symbolic links as links.
            let command: ArchiveCommand
            if urls.count == 1, let item = urls.first {
                command = ArchiveCommand(executablePath: "/usr/bin/ditto",
                                         arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", item.path, plan.stagedOutput.path],
                                         workingDirectory: folder)
            } else {
                command = ArchiveCommand(executablePath: plan.command.executablePath, arguments: ["-q"] + plan.command.arguments,
                                         workingDirectory: plan.command.workingDirectory)
            }
            setBusy(true, message: "Compressing…")
            let failure = await Self.runTool(command)
            setBusy(false, message: nil)
            defer { try? FileManager.default.removeItem(at: staging) }
            if let failure { show(message: "Couldn’t compress: \(failure)"); return }
            // The name was free when planned; if something took it meanwhile, pick the next one.
            var final = plan.finalOutput
            if FileManager.default.fileExists(atPath: final.path),
               let names = try? await fileSystem.childNames(of: folder),
               let name = try? UniqueNamer.name(for: final.lastPathComponent, existingNames: names) {
                final = folder.appendingPathComponent(name.value)
            }
            do { try FileManager.default.moveItem(at: plan.stagedOutput, to: final) }
            catch { show(message: "Couldn’t compress: \(error.localizedDescription)"); return }
            forgetUndoAfterUntrackedChange()
            store.send(.tab(tabID, .refreshSelecting([ItemID(url: final)])))
        }
    }

    /// Plain words for why an archive couldn't be planned, never an internal error code.
    static func compressionProblem(_ error: Error) -> String {
        guard let problem = error as? ArchivePlanningError else { return OperationText.describe(error) }
        switch problem {
        case .differentParents: return "Items from different folders can’t go in one archive."
        case .emptySelection: return "Nothing is selected."
        case .invalidPath, .invalidStagingDirectory: return "Helm can’t make an archive here."
        default: return "Helm couldn’t make the archive."
        }
    }

    /// Expands the selected archives with Archive Utility, as double-clicking one in Finder does. Like every app Helm
    /// hands files to, it goes through the launcher, so a fixture run never starts the real Archive Utility.
    func expandSelection() {
        let archives = selectedEntries().map(\.url).filter(Self.isExpandable)
        guard !archives.isEmpty else { NSSound.beep(); return }
        noteHandoff(of: archives, to: Self.archiveUtility)
        dependencies.launcher.open(archives, withApplicationAt: Self.archiveUtility, activates: false) { [weak self] error in
            guard let error else { return }
            self?.show(message: "Couldn’t expand: \(error.localizedDescription)")
        }
    }

    /// Archive Utility shows what it expanded through the file viewer, and brings the file viewer forward as it quits.
    /// Noting what Helm hands it, or DiskImageMounter, brings those back to Helm; the same from Finder goes to Finder.
    func noteHandoff(of urls: [URL], to application: URL) {
        dependencies.handoffs.record(urls, handedTo: application) { [weak self] folder in self?.namesListed(in: folder) }
    }

    /// The names the active tab lists in `folder` now, when it shows that folder and has finished loading it.
    public func namesListed(in folder: URL) -> Set<String>? {
        guard let tab = activeTab, tab.search == nil, !tab.isLoading,
              let here = tab.location.mutationTarget, Self.isSame(here, folder) else { return nil }
        return Set(tab.snapshot.sortedEntries.prefix(tab.snapshot.rootCount).map(\.name))
    }

    /// Runs a system tool off the main thread. Returns what went wrong, or nil.
    nonisolated static func runTool(_ command: ArchiveCommand) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executablePath)
            process.arguments = command.arguments
            process.currentDirectoryURL = command.workingDirectory
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: finished.terminationStatus == 0 ? nil : (text.isEmpty ? "the tool stopped with code \(finished.terminationStatus)" : text))
            }
            do { try process.run() } catch { continuation.resume(returning: error.localizedDescription) }
        }
    }
}
#endif
