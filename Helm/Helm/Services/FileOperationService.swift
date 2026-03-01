import Foundation
import AppKit

enum FileOperationServiceError: LocalizedError, Sendable {
    case fileCreationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .fileCreationFailed(let url):
            return "Could not create file at \(url.path)."
        }
    }
}

/// Progress reporting for file operations
struct OperationProgress: Identifiable, Sendable {
    let id: UUID
    let kind: OperationKind
    var currentFile: String
    var totalBytes: Int64
    var completedBytes: Int64
    var isCancelled: Bool = false
    var isComplete: Bool = false

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(completedBytes) / Double(totalBytes)
    }

    enum OperationKind: String, Sendable {
        case copy = "Copying"
        case move = "Moving"
        case trash = "Moving to Trash"
        case delete = "Deleting"
    }
}

/// Result of a file operation, used by UndoService to reverse it
struct FileOperationResult: Sendable {
    let kind: OperationResultKind
    let sourceURLs: [URL]
    let destinationURLs: [URL]

    enum OperationResultKind: Sendable {
        case copy
        case move
        case trash       // destinationURLs = trash URLs
        case rename      // sourceURLs[0] = old, destinationURLs[0] = new
        case createDirectory
        case createFile
    }
}

/// Actor handling all file operations with progress reporting
actor FileOperationService {

    private let fileManager = FileManager()

    // MARK: - Copy

    func copyItems(
        _ sourceURLs: [URL],
        to destinationDirectory: URL
    ) async throws -> FileOperationResult {
        var destinationURLs: [URL] = []

        for sourceURL in sourceURLs {
            let destURL = uniqueDestinationURL(
                for: sourceURL.lastPathComponent,
                in: destinationDirectory
            )
            try fileManager.copyItem(at: sourceURL, to: destURL)
            destinationURLs.append(destURL)
        }

        return FileOperationResult(
            kind: .copy,
            sourceURLs: sourceURLs,
            destinationURLs: destinationURLs
        )
    }

    // MARK: - Move

    func moveItems(
        _ sourceURLs: [URL],
        to destinationDirectory: URL
    ) async throws -> FileOperationResult {
        var destinationURLs: [URL] = []

        for sourceURL in sourceURLs {
            let destURL = uniqueDestinationURL(
                for: sourceURL.lastPathComponent,
                in: destinationDirectory
            )
            try fileManager.moveItem(at: sourceURL, to: destURL)
            destinationURLs.append(destURL)
        }

        return FileOperationResult(
            kind: .move,
            sourceURLs: sourceURLs,
            destinationURLs: destinationURLs
        )
    }

    // MARK: - Trash

    func trashItems(_ urls: [URL]) async throws -> FileOperationResult {
        var trashURLs: [URL] = []

        for url in urls {
            var resultingURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
            if let trashURL = resultingURL as URL? {
                trashURLs.append(trashURL)
            }
        }

        return FileOperationResult(
            kind: .trash,
            sourceURLs: urls,
            destinationURLs: trashURLs
        )
    }

    // MARK: - Permanent Delete

    func deleteItems(_ urls: [URL]) async throws {
        for url in urls {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - Rename

    func renameItem(at url: URL, to newName: String) async throws -> FileOperationResult {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try fileManager.moveItem(at: url, to: newURL)

        return FileOperationResult(
            kind: .rename,
            sourceURLs: [url],
            destinationURLs: [newURL]
        )
    }

    // MARK: - Create Directory

    func createDirectory(at parentURL: URL, name: String) async throws -> FileOperationResult {
        let dirURL = uniqueDestinationURL(for: name, in: parentURL)
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: false)

        return FileOperationResult(
            kind: .createDirectory,
            sourceURLs: [],
            destinationURLs: [dirURL]
        )
    }

    // MARK: - Create File

    func createFile(at parentURL: URL, name: String, contents: Data? = nil) async throws -> FileOperationResult {
        let fileURL = uniqueDestinationURL(for: name, in: parentURL)
        guard fileManager.createFile(atPath: fileURL.path, contents: contents) else {
            throw FileOperationServiceError.fileCreationFailed(fileURL)
        }

        return FileOperationResult(
            kind: .createFile,
            sourceURLs: [],
            destinationURLs: [fileURL]
        )
    }

    // MARK: - Create from Template

    func createFileFromTemplate(template: URL, in parentURL: URL) async throws -> FileOperationResult {
        let destURL = uniqueDestinationURL(for: template.lastPathComponent, in: parentURL)
        try fileManager.copyItem(at: template, to: destURL)

        return FileOperationResult(
            kind: .createFile,
            sourceURLs: [template],
            destinationURLs: [destURL]
        )
    }

    // MARK: - Helpers

    /// Generates a unique filename to avoid collisions (appends " 2", " 3", etc.)
    private func uniqueDestinationURL(for filename: String, in directory: URL) -> URL {
        var destURL = directory.appendingPathComponent(filename)

        if !fileManager.fileExists(atPath: destURL.path) {
            return destURL
        }

        let nameWithoutExtension = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        var counter = 2
        while fileManager.fileExists(atPath: destURL.path) {
            let newName = ext.isEmpty
                ? "\(nameWithoutExtension) \(counter)"
                : "\(nameWithoutExtension) \(counter).\(ext)"
            destURL = directory.appendingPathComponent(newName)
            counter += 1
        }

        return destURL
    }

    /// Check if source and destination are on the same volume
    func isSameVolume(_ url1: URL, _ url2: URL) -> Bool {
        let v1 = try? url1.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let v2 = try? url2.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let v1, let v2 else { return false }
        return v1.isEqual(v2)
    }
}
