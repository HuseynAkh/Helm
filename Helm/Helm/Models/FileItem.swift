import Foundation
import UniformTypeIdentifiers
import AppKit

struct FileItem: Identifiable, Hashable {
    let id: URL
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let size: Int64
    let modificationDate: Date
    let creationDate: Date
    let contentType: UTType?
    let isPackage: Bool
    var isStarred: Bool

    var displayName: String {
        name
    }

    var fileExtension: String {
        url.pathExtension
    }

    static let prefetchKeys: Set<URLResourceKey> = [
        .nameKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .fileSizeKey,
        .totalFileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .contentTypeKey,
        .isPackageKey
    ]

    static func from(url: URL, starredService: StarredFilesService? = nil) throws -> FileItem {
        let resourceValues = try url.resourceValues(forKeys: prefetchKeys)

        return FileItem(
            id: url,
            url: url,
            name: resourceValues.name ?? url.lastPathComponent,
            isDirectory: resourceValues.isDirectory ?? false,
            isSymlink: resourceValues.isSymbolicLink ?? false,
            isHidden: resourceValues.isHidden ?? false,
            size: Int64(resourceValues.totalFileSize ?? resourceValues.fileSize ?? 0),
            modificationDate: resourceValues.contentModificationDate ?? Date.distantPast,
            creationDate: resourceValues.creationDate ?? Date.distantPast,
            contentType: resourceValues.contentType,
            isPackage: resourceValues.isPackage ?? false,
            isStarred: starredService?.isStarred(url: url) ?? false
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }
}
