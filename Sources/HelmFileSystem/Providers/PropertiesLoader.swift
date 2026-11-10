import Foundation
import HelmCore

/// Read-only file attributes for Properties; images and application enrichment belong to UI (F-062).
public struct PropertiesLoader: Sendable {
    private let fileSystem: any FileSystem
    public init(fileSystem: any FileSystem) { self.fileSystem = fileSystem }
    public func properties(for url: URL) async throws -> FileEntry { try await fileSystem.entry(at: url) }
    public func sizeOfTree(at url: URL) -> AsyncThrowingStream<Int64, Error> { fileSystem.sizeOfTree(at: url) }
}
