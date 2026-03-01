import Foundation
import Testing
@testable import Helm

func registerFileManagerFlowTests() {
    TestRuntime.register("FileOperationService full file lifecycle") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("helm-flow-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fileOps = FileOperationService()
        let fileSystem = FileSystemService()

        let create = try await fileOps.createFile(at: source, name: "alpha.txt", contents: Data("alpha".utf8))
        try Check.equal(create.destinationURLs.count, 1, "Create should produce exactly one destination URL")

        let createdURL = create.destinationURLs[0]
        try Check.isTrue(fm.fileExists(atPath: createdURL.path), "Newly created file should exist")

        let rename = try await fileOps.renameItem(at: createdURL, to: "beta.txt")
        let renamedURL = rename.destinationURLs[0]
        try Check.isTrue(fm.fileExists(atPath: renamedURL.path), "Renamed file should exist")
        try Check.isTrue(!fm.fileExists(atPath: createdURL.path), "Old filename should no longer exist after rename")

        _ = try await fileOps.copyItems([renamedURL], to: destination)
        let destinationCopy = destination.appendingPathComponent("beta.txt")
        try Check.isTrue(fm.fileExists(atPath: destinationCopy.path), "Copied file should exist in destination")

        _ = try await fileOps.moveItems([renamedURL], to: destination)
        let movedURL = destination.appendingPathComponent("beta 2.txt")
        try Check.isTrue(fm.fileExists(atPath: movedURL.path), "Moved file should exist with collision-safe name")

        let sourceItems = try await fileSystem.contentsOfDirectory(at: source)
        try Check.equal(sourceItems.count, 0, "Source directory should be empty after moving the only file")
    }

    TestRuntime.register("DirectoryViewModel directory navigation flow") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("helm-vm-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("note".utf8).write(to: root.appendingPathComponent("note.txt"))
        defer { try? fm.removeItem(at: root) }

        let vm = await MainActor.run {
            DirectoryViewModel(
                fileSystemService: FileSystemService(),
                starredService: StarredFilesService(),
                fileMonitor: FileMonitorService()
            )
        }

        await MainActor.run {
            vm.currentURL = root
        }
        await vm.loadDirectory()

        let rootNames = await MainActor.run { Set(vm.items.map(\.name)) }
        try Check.isTrue(rootNames.contains("Child"), "Root listing should include child folder")
        try Check.isTrue(rootNames.contains("note.txt"), "Root listing should include file")

        await vm.navigateTo(child)
        let currentPath = await MainActor.run { vm.currentURL.path }
        try Check.equal(currentPath, child.path, "View model should update current URL after navigation")
    }

    #if DEBUG
    TestRuntime.register("FileListViewController wires callbacks after view load") {
        let vm = await MainActor.run {
            DirectoryViewModel(
                fileSystemService: FileSystemService(),
                starredService: StarredFilesService(),
                fileMonitor: FileMonitorService()
            )
        }

        let vc = await MainActor.run {
            FileListViewController(viewModel: vm)
        }
        _ = await MainActor.run { vc.view }

        let initiallyWired = await MainActor.run { vc.debugHasWiredCallbacks() }
        try Check.isTrue(!initiallyWired, "Callbacks should be nil before assignment")

        await MainActor.run {
            vc.onNavigate = { _ in }
            vc.onOpenItem = { _ in }
            vc.onContextMenu = { _, _, _ in }
            vc.onSelectionChanged = {}
            vc.onDirectoryMutated = {}
        }

        let wiredAfterAssignment = await MainActor.run { vc.debugHasWiredCallbacks() }
        try Check.isTrue(wiredAfterAssignment, "Callbacks should be wired even when assigned after view creation")
    }
    #endif

    TestRuntime.register("SidebarViewModel bookmarks support drag/drop targets and selection mapping") {
        let fm = FileManager.default
        let bookmarkRoot = fm.temporaryDirectory.appendingPathComponent("helm-bookmark-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: bookmarkRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bookmarkRoot) }

        let vm = await MainActor.run { SidebarViewModel() }
        await MainActor.run {
            vm.addBookmark(url: bookmarkRoot)
            vm.selectLocation(bookmarkRoot)
        }

        let result = await MainActor.run { (vm.bookmarks, vm.selectedPlaceID) }
        try Check.isTrue(result.0.contains(where: { $0.url.standardizedFileURL == bookmarkRoot.standardizedFileURL }),
                         "Added bookmark should be present in sidebar model")
        try Check.notNil(result.1, "Selecting bookmarked location should set selected place ID")
    }

    TestRuntime.register("SidebarViewModel highlights Home for nested folders") {
        let vm = await MainActor.run { SidebarViewModel() }
        let nested = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")

        await MainActor.run {
            vm.selectLocation(nested)
        }

        let selected = await MainActor.run { vm.selectedPlaceID }
        try Check.notNil(selected, "Nested Home location should map to a known highlighted place")
    }

    TestRuntime.register("SidebarViewModel maps virtual recents location to recents root button") {
        let vm = await MainActor.run { SidebarViewModel() }
        await MainActor.run {
            vm.selectLocation(.helmRecentsURL)
        }

        let selected = await MainActor.run { vm.selectedPlaceID }
        try Check.equal(selected, "recent-root", "Virtual recents location should highlight the top Recent button")
    }
}
