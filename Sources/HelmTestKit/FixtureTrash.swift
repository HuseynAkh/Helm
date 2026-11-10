import Foundation

/// Stands in for the system Trash, so tests of live mutations never touch the user's real one.
public func fixtureTrash(in folder: URL) -> @Sendable (URL) throws -> URL? {
    { url in
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}
