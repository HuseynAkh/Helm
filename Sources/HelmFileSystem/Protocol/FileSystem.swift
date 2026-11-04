// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Bounded listing batches preserve hidden-file preference (F-042).
public struct EnumerationOptions: Sendable, Equatable {
    public var includeHidden: Bool
    public var batchSize: Int
    public var resolveSymlinkTargets: Bool
    public init(includeHidden: Bool = false, batchSize: Int = 512, resolveSymlinkTargets: Bool = true) {
        self.includeHidden = includeHidden; self.batchSize = max(1, batchSize)
        self.resolveSymlinkTargets = resolveSymlinkTargets
    }
}
/// Portable failures distinguish inaccessible Trash from an empty listing (B-109).
public enum FileSystemError: Error, Sendable, Equatable {
    /// A collision permits retry only when the primitive guarantees it made no mutation (B-038).
    case collision(noMutation: Bool)
    case notFound, permissionDenied, timedOut, unsupported, other(String)
    public static func mapping(_ error: Error) -> FileSystemError {
        if let error = error as? FileSystemError { return error }
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain {
            if value.code == 17 { return .collision(noMutation: false) }
            if value.code == 2 { return .notFound }
            if value.code == 1 || value.code == 13 { return .permissionDenied }
        }
        if value.domain == NSCocoaErrorDomain {
            if value.code == 516 { return .collision(noMutation: false) }
            if [4, 260].contains(value.code) { return .notFound }
            if [257, 513].contains(value.code) { return .permissionDenied }
        }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return mapping(underlying) }
        return .other(value.localizedDescription)
    }
}
/// Injectable filesystem boundary preserves listing and safe mutations (F-035, F-052, B-039).
public protocol FileSystem: Sendable {
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error>
    func entry(at url: URL) async throws -> FileEntry
    func exists(_ url: URL) async -> Bool
    func isDirectory(_ url: URL, resolvingSymlinks: Bool) async -> Bool
    func childNames(of directory: URL) async throws -> Set<String>
    func copyItem(at source: URL, to destination: URL) async throws
    func moveItem(at source: URL, to destination: URL) async throws
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws
    func trashItem(at url: URL) async throws -> URL?
    func removeItem(at url: URL) async throws
    func createDirectory(at url: URL) async throws
    func createFileExclusively(at url: URL, contents: Data) async throws
    func createSymbolicLink(at url: URL, destination: URL) async throws
    func createAlias(for url: URL, at destination: URL) async throws
    func isCaseSensitive(at url: URL) async throws -> Bool
    func volumeIdentifier(for url: URL) async throws -> String
    func availableCapacity(of url: URL) async throws -> Int64
    func sizeOfTree(at url: URL) -> AsyncThrowingStream<Int64, Error>
    func makeMonitor(for directory: URL) -> any DirectoryMonitor
}
/// Monitor lifetime is explicit; each handle belongs to one consumer (B-072).
public protocol DirectoryMonitor: Sendable {
    var events: AsyncStream<MonitorEvent> { get }
    func start() async throws
    func stop() async
}
/// Loading distinguishes batches from successful completion (B-017).
public enum LoadEvent: Sendable { case batch([FileEntry]), finished, warning(String) }
/// Access decision for future sandbox adapters (B-109).
public struct AccessGrant: Sendable {
    public let url: URL
    public let allowed: Bool
    public init(url: URL, allowed: Bool) { self.url = url; self.allowed = allowed }
}
/// Broker owns any security-scope lifetime (B-109).
public protocol AccessBroker: Sendable { func access(_ url: URL) async -> AccessGrant }

public extension FileSystem {
    /// Unknown volume semantics are conservatively case-insensitive (F-052/B-039).
    func isCaseSensitive(at url: URL) async throws -> Bool { false }
    func stat(_ url: URL) async throws -> FileEntry { try await entry(at: url) }
    func isDirectory(_ url: URL, resolvingSymlinks: Bool = true) async -> Bool {
        guard let value = try? await entry(at: url) else { return false }
        return value.kind == .directory || (resolvingSymlinks && value.kind == .symlinkToDirectory)
    }
    func childNames(of directory: URL) async throws -> Set<String> {
        var names = Set<String>()
        for try await batch in enumerate(directory, options: EnumerationOptions(includeHidden: true)) {
            names.formUnion(batch.map(\.name))
        }
        return names
    }
    func sizeOfTree(at url: URL) -> AsyncThrowingStream<Int64, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var total: Int64 = 0
                    var pending = [url]
                    while let current = pending.popLast() {
                        try Task.checkCancellation()
                        let value = try await entry(at: current)
                        if value.kind == .directory || value.kind == .package {
                            for try await batch in enumerate(current, options: EnumerationOptions(includeHidden: true)) {
                                pending.append(contentsOf: batch.map(\.url))
                            }
                        } else {
                            let sum = total.addingReportingOverflow(value.size)
                            guard !sum.overflow else { throw FileSystemError.other("Size overflow") }
                            total = sum.partialValue
                        }
                        continuation.yield(total)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func makeMonitor(for directory: URL) -> any DirectoryMonitor { PollingMonitor(directory: directory, fileSystem: self) }
}
