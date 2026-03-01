import Foundation
import Testing
@testable import Helm

func registerFileSystemServiceTests() {
    TestRuntime.register("FileSystemService lists visible items and filters hidden ones") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("helm-fs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let visible = base.appendingPathComponent("Visible.txt")
        let hidden = base.appendingPathComponent(".Hidden.txt")
        try Data("visible".utf8).write(to: visible)
        try Data("hidden".utf8).write(to: hidden)

        let service = FileSystemService()

        let defaultItems = try await service.contentsOfDirectory(at: base)
        try Check.equal(defaultItems.count, 1, "Default listing should hide hidden files")
        try Check.equal(defaultItems.first?.name, "Visible.txt", "Visible file should be listed")

        let allItems = try await service.contentsOfDirectory(at: base, showHidden: true)
        try Check.equal(allItems.count, 2, "Listing with hidden enabled should include all files")
    }

    TestRuntime.register("FileSystemService creates file items with accurate names") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("helm-fs-item-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let fileURL = base.appendingPathComponent("Document.md")
        try Data("doc".utf8).write(to: fileURL)

        let service = FileSystemService()
        let item = try await service.fileItem(at: fileURL)

        try Check.equal(item.name, "Document.md", "File item should use last path component for name")
        try Check.equal(item.url.lastPathComponent, item.name, "File item name should match URL component")
        try Check.isTrue(!item.isDirectory, "Created item should be detected as a file")
    }

    TestRuntime.register("FileSystemService directory detection works") {
        let service = FileSystemService()
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("helm-fs-dir-\(UUID().uuidString)", isDirectory: true)
        let childDir = base.appendingPathComponent("Child", isDirectory: true)
        try fm.createDirectory(at: childDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let exists = await service.exists(at: childDir)
        let isDirectory = await service.isDirectory(at: childDir)
        let parent = await service.parentDirectory(of: childDir)
        try Check.isTrue(exists, "Created directory should exist")
        try Check.isTrue(isDirectory, "Directory detection should return true for folders")
        try Check.equal(parent, base, "Parent directory should be resolved correctly")
    }
}
