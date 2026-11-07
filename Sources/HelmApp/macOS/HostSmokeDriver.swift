#if os(macOS)
import AppKit
import HelmCore
import HelmOperations
import HelmUI
import Quartz

/// Runs a scripted session against the real window with a fixture home, then quits. Each line is a step.
/// This is how the app is exercised without a person: real views, real store, real file system, temp folders only.
@MainActor enum HostSmokeDriver {
    private static var failures = 0

    static func run(script: URL, app: AppController) {
        guard let text = try? String(contentsOf: script, encoding: .utf8) else { finish(code: 2, "cannot read script"); return }
        let steps = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        Task { @MainActor in
            await wait(seconds: 0.6)
            for step in steps {
                await perform(step, app: app)
            }
            finish(code: failures == 0 ? 0 : 1, failures == 0 ? "all steps passed" : "\(failures) failed")
        }
    }

    private static func finish(code: Int32, _ message: String) {
        print("SMOKE_END \(code == 0 ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
        exit(code)
    }
    private static func check(_ condition: Bool, _ step: String, _ detail: @autoclosure () -> String = "") {
        print("\(condition ? "PASS" : "FAIL") \(step)\(condition ? "" : " :: \(detail())")")
        fflush(stdout)
        if !condition { failures += 1 }
    }
    private static func wait(seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private static func perform(_ step: String, app: AppController) async {
        let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts[0], argument = parts.count > 1 ? parts[1] : ""
        guard let window = app.frontmost() else { check(false, step, "no window"); return }
        window.messageObserver = { print("MSG \($0)"); fflush(stdout) }
        window.confirmsForTesting = true
        var tab: TabState? { app.frontmost()?.activeTab }
        var names: [String] { tab.map { $0.snapshot.sortedEntries.prefix($0.snapshot.rootCount).map(\.name) } ?? [] }
        switch verb {
        case "wait":
            await wait(seconds: Double(argument) ?? 0.5)
        case "windows":
            check(app.allWindows.count == Int(argument), step, "count \(app.allWindows.count)")
        case "tabs":
            check(window.store.state.window.tabs.count == Int(argument), step, "count \(window.store.state.window.tabs.count)")
        case "cmd":
            guard let command = CommandID(rawValue: argument) else { check(false, step, "unknown command"); return }
            window.perform(command)
            await wait(seconds: 0.5)
        case "go":
            window.navigate(to: .directory(URL(fileURLWithPath: argument, isDirectory: true)))
            await wait(seconds: 0.5)
        case "type":
            window.store.send(.tab(window.activeTabID, .addressBar(.beginEditing)))
            window.store.send(.tab(window.activeTabID, .addressBar(.textChanged(argument))))
            await wait(seconds: 0.3)
        case "typed-rows":
            let rows = tab?.addressBar.rows.map(\.name) ?? []
            check(rows.joined(separator: ",") == argument, step, rows.joined(separator: ","))
        case "return":
            window.store.send(.tab(window.activeTabID, .addressBar(.returnKey)))
            await wait(seconds: 0.5)
        case "location":
            let path = tab?.location.mutationTarget?.standardizedFileURL.path ?? tab.map { "\($0.location.kind)" } ?? ""
            let wanted = argument.hasPrefix("/") ? URL(fileURLWithPath: argument).standardizedFileURL.path : argument
            check(PathSpelling.identity(path) == PathSpelling.identity(wanted), step, path)
        case "lists":
            let wanted = argument.split(separator: ",").map(String.init)
            check(names == wanted, step, names.joined(separator: ","))
        case "has":
            check(names.contains(argument), step, names.joined(separator: ","))
        case "lacks":
            check(!names.contains(argument), step, names.joined(separator: ","))
        case "select":
            guard let tab else { return }
            let chosen = Set(argument.split(separator: ",").map(String.init))
            let ids = tab.snapshot.sortedEntries.filter { chosen.contains($0.name) }.map(\.id)
            window.store.send(.tab(tab.id, .setSelection(Set(ids), source: .user)))
            await wait(seconds: 0.1)
        case "selected":
            let selected = tab.map { value in value.snapshot.sortedEntries.filter { value.selection.contains($0.id) }.map(\.name) } ?? []
            check(selected.joined(separator: ",") == argument, step, selected.joined(separator: ","))
        case "rename":
            guard let entry = window.selectedEntries().first else { check(false, step, "nothing selected"); return }
            window.commitRename(entry, to: argument)
            await wait(seconds: 0.6)
        case "view":
            window.perform(argument == "grid" ? .grid : .list)
            await wait(seconds: 0.3)
        case "search":
            window.search(argument)
            await wait(seconds: 0.8)
        case "setting":
            let bits = argument.split(separator: " ").map(String.init)
            guard bits.count == 2, let key = SettingKey(rawValue: "helm." + bits[0]) else { check(false, step, "bad setting"); return }
            app.setting(key, to: bits[1] == "true")
        case "expand":
            guard let tab, let entry = tab.snapshot.sortedEntries.first(where: { $0.name == argument }) else { check(false, step, "no such row"); return }
            window.store.send(.tab(tab.id, .expand(entry.id)))
            await wait(seconds: 0.4)
        case "child":
            let bits = argument.split(separator: "/").map(String.init)
            let visible = tab.map { value in value.snapshot.visibleIDs(expanding: value.expandedIDs).compactMap { value.snapshot.entry($0)?.name } } ?? []
            check(bits.allSatisfy(visible.contains), step, visible.joined(separator: ","))
        case "close-window":
            window.window?.performClose(nil)
            await wait(seconds: 0.3)
        case "starred":
            check(app.frontmost()?.dependencies.stars.records.contains { URL(fileURLWithPath: $0.path).lastPathComponent == argument } ?? false, step)
        case "unstarred":
            check(!(app.frontmost()?.dependencies.stars.records.contains { URL(fileURLWithPath: $0.path).lastPathComponent == argument } ?? false), step)
        case "undo-title":
            await window.refreshHistoryForTesting()
            check(window.undoTitleForTesting == argument, step, window.undoTitleForTesting)
        case "contents":
            let bits = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let found = (try? String(contentsOfFile: bits[0], encoding: .utf8)) ?? "<unreadable>"
            check(bits.count == 2 && found.trimmingCharacters(in: .whitespacesAndNewlines) == bits[1], step, found)
        case "same-mtime":
            let bits = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let dates = bits.map { (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date }
            check(dates.count == 2 && dates[0] != nil && dates[0] == dates[1], step, "\(dates)")
        case "has-xattr":
            let bits = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let size = bits.count == 2 ? getxattr(bits[0], bits[1], nil, 0, 0, XATTR_NOFOLLOW) : -1
            check(size >= 0, step)
        case "is-link":
            let kind = try? FileManager.default.attributesOfItem(atPath: argument)[.type] as? FileAttributeType
            check(kind == .typeSymbolicLink, step)
        case "conflict":
            window.conflictChoiceForTesting = ConflictResolution(rawValue: argument)
        case "sheet":
            check(window.hasSheetForTesting, step)
        case "dismiss-sheet":
            window.dismissSheetForTesting()
            await wait(seconds: 0.3)
        case "quicklook":
            window.perform(.quickLook)
            await wait(seconds: 1.5)
            let visible = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
            check(visible == (argument == "open"), step, "visible \(visible)")
        case "settings-window":
            window.perform(.settings)
            await wait(seconds: 0.5)
            let settings = app.settingsWindowForTesting
            check(settings?.isVisible == true, step)
            settings?.close()
        case "menu":
            // menu <command> <enabled|disabled> [title]
            let bits = argument.split(separator: " ", maxSplits: 2).map(String.init)
            guard bits.count >= 2, let command = CommandID(rawValue: bits[0]) else { check(false, step, "bad step"); return }
            await window.refreshHistoryForTesting()
            let (title, enabled) = window.title(of: command)
            check(enabled == (bits[1] == "enabled") && (bits.count < 3 || title == bits[2]), step, "\(title), enabled \(enabled)")
        case "inline-rename":
            window.perform(.rename)
            await wait(seconds: 0.3)
            check(window.isRenamingForTesting, "\(step) (editing started)")
            window.typeIntoRenameFieldForTesting(argument, cancel: false)
            await wait(seconds: 0.7)
        case "inline-cancel":
            window.perform(.rename)
            await wait(seconds: 0.3)
            check(window.isRenamingForTesting, "\(step) (editing started)")
            window.typeIntoRenameFieldForTesting(argument, cancel: true)
            await wait(seconds: 0.5)
        case "drop":
            // drop <name in this folder> <destination folder path>
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2, let entry = tab?.snapshot.sortedEntries.first(where: { $0.name == bits[0] }) else { check(false, step, "no such row"); return }
            check(window.dropForTesting([entry.url], into: URL(fileURLWithPath: bits[1], isDirectory: true)), step)
            await wait(seconds: 0.6)
        case "drop-refused":
            // drop-refused <name in this folder> <destination folder path>: refused before anything moves.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2, let entry = tab?.snapshot.sortedEntries.first(where: { $0.name == bits[0] }) else { check(false, step, "no such row"); return }
            check(!window.dropForTesting([entry.url], into: URL(fileURLWithPath: bits[1], isDirectory: true)), step, "accepted")
        case "openwith-ranked":
            // Open With offers a default, lists each app once, and never puts an app in two groups.
            guard let entry = tab?.snapshot.sortedEntries.first(where: { $0.name == argument }) else { check(false, step, "no such row"); return }
            let summary = window.openWithSummaryForTesting(entry)
            check(summary.defaultName != nil && summary.apps == summary.distinct && summary.recommended > 0, step,
                  "default \(summary.defaultName ?? "none"), \(summary.apps) apps, \(summary.distinct) distinct, \(summary.recommended) recommended")
        case "bookmark":
            window.sidebarDropForTesting([URL(fileURLWithPath: argument, isDirectory: true)])
            await wait(seconds: 0.3)
        case "bookmarked":
            check(window.dependencies.bookmarks.records.contains { URL(fileURLWithPath: $0.path).lastPathComponent == argument }, step)
        case "view-is":
            check(tab?.viewMode.rawValue == argument, step, tab?.viewMode.rawValue ?? "")
        case "sorted-by":
            check(tab?.sort.field.rawValue == argument, step, tab?.sort.field.rawValue ?? "")
        case "sort":
            guard let field = ItemSort.Field(rawValue: argument), let current = tab?.sort else { check(false, step, "bad field"); return }
            window.contentSetSortForTesting(current.toggling(field: field))
            await wait(seconds: 0.4)
        case "sort-choose":
            window.chooseSortForTesting(argument)
            await wait(seconds: 0.4)
        case "sort-is":
            let current = tab.map { SortChoice.matching($0.sort).title } ?? ""
            check(current == argument, step, current)
        case "first-row":
            check(names.first == argument, step, names.first ?? "")
        case "path-reads":
            let segments = window.pathSegmentsForTesting().joined(separator: " / ")
            check(segments == argument, step, segments)
        case "drive-listed":
            check(window.sidebarDriveNamesForTesting.contains(argument), step, window.sidebarDriveNamesForTesting.joined(separator: ","))
        case "text-step":
            window.stepText(by: Int(argument) ?? 0)
            await wait(seconds: 0.3)
        case "text-percent":
            check(window.textPercent == Int(argument), step, "\(window.textPercent)%")
        case "sort-press":
            guard let field = SortField.all.first(where: { $0.title == argument }) else { check(false, step, "no such field"); return }
            window.pressSort(field.field)
            await wait(seconds: 0.4)
        case "search-open":
            window.perform(.find)
            await wait(seconds: 0.2)
            check(window.isSearchingForTesting, step)
        case "keep-open":
            // Holds a run open so the real window can be looked at from outside.
            await wait(seconds: Double(argument) ?? 60)
        case "star-now":
            guard let tab, let entry = tab.snapshot.sortedEntries.first(where: { $0.name == argument }) else { check(false, step, "no such row"); return }
            window.dependencies.stars.star(entry.url, at: Date())
        case "quit":
            // The real path: wait for operations, save, then exit. A failure to save would leave this running.
            print("SMOKE_QUIT"); fflush(stdout)
            // From the run loop, as the Quit menu does. Terminating from a task would hold the main queue during the wait.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            await wait(seconds: 5)
            check(false, step, "still running 5 seconds after quit")
        case "commit-rename":
            window.window?.makeFirstResponder(nil)
            await wait(seconds: 0.2)
        case "window-empty-trash":
            window.emptyTrashForTesting()
            await wait(seconds: 0.6)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: window.dependencies.home.appendingPathComponent(".Trash").path)) ?? ["?"]
            check(left.isEmpty, "empty trash cleared the fixture Trash", left.joined(separator: ","))
        case "recent":
            window.navigate(to: .recent)
            await wait(seconds: 0.4)
        case "window-trash":
            window.navigate(to: .trash)
            await wait(seconds: 0.5)
            check(names.contains("trash-me.txt"), "trash lists trash-me.txt", names.joined(separator: ","))
            guard let tab, let entry = tab.snapshot.sortedEntries.first(where: { $0.name == "trash-me.txt" }) else { return }
            window.store.send(.tab(tab.id, .setSelection([entry.id], source: .user)))
            await wait(seconds: 0.1)
            window.perform(.putBack)
            await wait(seconds: 0.7)
            let back = FileManager.default.fileExists(atPath: tab.lastDirectory?.appendingPathComponent("trash-me.txt").path ?? "")
            check(back, "put back restored trash-me.txt")
            window.perform(.back)
            await wait(seconds: 0.5)
        case "watch-external":
            // Another process creating a file: the monitor, not a refresh command, must pick it up.
            FileManager.default.createFile(atPath: argument, contents: Data("x".utf8))
        case "exists":
            check(FileManager.default.fileExists(atPath: argument), step)
        case "missing":
            check(!FileManager.default.fileExists(atPath: argument), step)
        case "main-thread-clean":
            // The open crash test leaves the main thread believing it is inside a task after a watch is cancelled.
            // Check that from outside any task, on the real run loop, after real cancellations.
            let clean: Bool = await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    continuation.resume(returning: withUnsafeCurrentTask { $0 == nil })
                }
            }
            check(clean, step)
        case "popover-shot":
            // Opens the view options popover and captures it.
            guard let content = window.showViewOptionsForTesting() else { check(false, step, "no popover"); return }
            await wait(seconds: 0.6)
            let target = content.superview ?? content
            guard let image = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { check(false, step, "no image"); return }
            target.cacheDisplay(in: target.bounds, to: image)
            let data = image.representation(using: .png, properties: [:])
            try? data?.write(to: URL(fileURLWithPath: argument))
            window.closeViewOptionsForTesting()
            await wait(seconds: 0.3)
            check(data != nil, step)
        case "screenshot":
            // The frame view, so the capture includes the toolbar and window background.
            guard let content = window.window?.contentView?.superview, let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                check(false, step, "no view"); return
            }
            content.cacheDisplay(in: content.bounds, to: image)
            let data = image.representation(using: .png, properties: [:])
            try? data?.write(to: URL(fileURLWithPath: argument))
            check(data != nil, step)
        default:
            check(false, step, "unknown step")
        }
    }
}
#endif
