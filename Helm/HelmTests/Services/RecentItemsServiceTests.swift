import Foundation
import Testing
@testable import Helm

func registerRecentItemsServiceTests() {
    TestRuntime.register("RecentItemsService records and orders file/folder accesses") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("helm-recent-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let file = root.appendingPathComponent("note.txt")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: file)
        defer { try? fm.removeItem(at: root) }

        let suiteName = "helm.recent.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "HelmTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create isolated defaults suite"])
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = RecentItemsService(defaults: defaults)
        await service.recordAccess(to: folder)
        try await Task.sleep(nanoseconds: 5_000_000)
        await service.recordAccess(to: file)

        let urls = await service.recentURLs(limit: 5)
        try Check.equal(urls.count, 2, "Both folder and file should be tracked as recent entries")
        try Check.equal(urls.first?.standardizedFileURL, file.standardizedFileURL, "Most recently accessed item should be first")
        try Check.equal(urls.last?.standardizedFileURL, folder.standardizedFileURL, "Older access should appear later")

        defaults.removePersistentDomain(forName: suiteName)
    }

    TestRuntime.register("RecentItemsService prunes missing files and returns valid FileItem payloads") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("helm-recent-prune-\(UUID().uuidString)", isDirectory: true)
        let aliveFile = root.appendingPathComponent("alive.txt")
        let goneFile = root.appendingPathComponent("gone.txt")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: aliveFile)
        try Data("b".utf8).write(to: goneFile)
        defer { try? fm.removeItem(at: root) }

        let suiteName = "helm.recent.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "HelmTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create isolated defaults suite"])
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = RecentItemsService(defaults: defaults)
        await service.recordAccess(to: goneFile)
        await service.recordAccess(to: aliveFile)
        try fm.removeItem(at: goneFile)

        let items = await service.recentItems(limit: 10)
        try Check.equal(items.count, 1, "Missing files should be pruned from recents")
        try Check.equal(items[0].url.standardizedFileURL, aliveFile.standardizedFileURL, "Only existing items should be emitted")

        defaults.removePersistentDomain(forName: suiteName)
    }
}
