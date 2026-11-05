import Foundation

/// Isolated disk fixture for file-operation tests (F-052, F-058); cleanup is explicit and idempotent.
public final class TempDirectory {
    public let url: URL
    public init(parent: URL = FileManager.default.temporaryDirectory) throws {
        url = parent.appendingPathComponent("helm-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    public func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
