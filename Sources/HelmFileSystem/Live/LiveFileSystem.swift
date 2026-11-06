// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// FileManager implementation preserves nonrecursive listings and exclusive creation (F-035, B-039).
public struct LiveFileSystem: FileSystem {
    private let executor: IOExecutor
    private let volumeRoots: [URL]
    private var readMetadata: @Sendable (URL, Bool, String) throws -> FileEntry = {
        try MetadataReader().read($0, resolveSymlinkTargets: $1, volumeIdentifier: $2)
    }
    private let diagnostic: @Sendable (URL, FileSystemError) -> Void
    private let trash: @Sendable (URL) throws -> URL?
    /// `trash` is injectable so tests never touch the user's real Trash.
    public init(executor: IOExecutor = IOExecutor(), volumeRoots: [URL] = [],
                diagnostic: @escaping @Sendable (URL, FileSystemError) -> Void = { _, _ in },
                trash: @escaping @Sendable (URL) throws -> URL? = LiveFileSystem.systemTrash) {
        self.executor = executor; self.volumeRoots = volumeRoots
        self.diagnostic = diagnostic; self.trash = trash
    }
    public static let systemTrash: @Sendable (URL) throws -> URL? = { url in
        #if os(macOS)
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
        #else
        throw FileSystemError.unsupported
        #endif
    }
    init(readMetadata: @escaping @Sendable (URL, Bool, String) throws -> FileEntry) {
        self.init()
        self.readMetadata = readMetadata
    }
    private func queueKey(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let root = volumeRoots.sorted(by: { $0.path.count > $1.path.count }).first(where: {
            path == $0.path || path.hasPrefix($0.path + "/")
        }) { return root.path }
        let components = url.pathComponents
        if components.count > 2 && components[1] == "Volumes" { return "/Volumes/" + components[2] }
        return "/"
    }
    public func enumerate(_ directory: URL, options: EnumerationOptions = EnumerationOptions()) -> AsyncThrowingStream<[FileEntry], Error> {
        AsyncThrowingStream { continuation in
            let cancellation = EnumerationCancellation()
            let task = Task {
                do {
                    try await executor.runReadWithProgress(volume: queueKey(directory)) { progress in
                        try cancellation.check()
                        // opendir provides an O(1) permission preflight without materializing 100k URLs.
                        guard let handle = opendir(directory.path) else {
                            throw FileSystemError.mapping(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
                        }
                        closedir(handle)
                        var failure: Error?
                        let flags: FileManager.DirectoryEnumerationOptions = options.includeHidden
                            ? [.skipsSubdirectoryDescendants] : [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
                        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: MetadataReader.listingPrefetchKeys,
                            options: flags, errorHandler: { _, error in failure = error; return false }) else {
                            throw FileSystemError.notFound
                        }
                        var batch: [FileEntry] = []
                        var lastDelivery = Date()
                        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                        let volume = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? queueKey(directory)
                        while let url = iterator.nextObject() as? URL {
                            try cancellation.check()
                            let value: FileEntry
                            do {
                                value = try AutoreleaseScope.run {
                                    try readMetadata(url, options.resolveSymlinkTargets, volume)
                                }
                            } catch {
                                let mapped = FileSystemError.mapping(error)
                                // A vanished child is a removal, not an incomplete listing (F-035).
                                if mapped == .notFound { continue }
                                diagnostic(url, mapped)
                                throw mapped
                            }
                            if !options.includeHidden && value.isHidden { continue }
                            batch.append(value)
                            if batch.count >= max(1, options.batchSize) || Date().timeIntervalSince(lastDelivery) >= 0.05 {
                                progress(); continuation.yield(batch); batch.removeAll(keepingCapacity: true); lastDelivery = Date()
                            }
                        }
                        if let failure { throw FileSystemError.mapping(failure) }
                        if !batch.isEmpty { continuation.yield(batch) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in cancellation.cancel(); task.cancel() }
        }
    }
    public func makeMonitor(for directory: URL) -> any DirectoryMonitor {
        FallbackMonitor(directory: directory, fileSystem: self)
    }
    /// Native metadata supplies no-follow inode evidence for the bounded-race contract (O1-1).
    public func mutationPrecondition(at source: URL) async throws -> FileMutationPrecondition {
        let value = try await entry(at: source)
        guard let identity = value.objectIdentity else { throw ConditionalMutationError.unsupported }
        return FileMutationPrecondition(identity: identity, changeToken: value.changeToken, kind: value.kind)
    }
    /// Compare, admit exclusively, mutate (O1-1 option A). macOS has no atomic compare-identity-and-rename,
    /// so a small window remains between the comparison and the mutation, disclosed in OWNER_RULINGS.md.
    /// Linux keeps the refusal: nothing ships there and its primitives were never reviewed for this.
    public func mutate(_ mutation: ConditionalFileMutation, source: URL,
                       requiring precondition: FileMutationPrecondition) async throws -> URL? {
        #if os(macOS)
        if Task.isCancelled { throw ConditionalMutationError.cancelledBeforeMutation }
        let volumes: [String]
        switch mutation {
        case .copy(let destination), .move(let destination): volumes = [queueKey(source), queueKey(destination)]
        case .trash: volumes = [queueKey(source)]
        }
        let read = readMetadata, trash = self.trash
        let cancellation = EnumerationCancellation()
        do {
            return try await withTaskCancellationHandler {
                try await executor.runWithProgress(volumes: volumes) { progress -> URL? in
                    let current = try read(source, true, "")
                    guard current.objectIdentity == precondition.identity, current.kind == precondition.kind,
                          current.changeToken == precondition.changeToken else {
                        throw ConditionalMutationError.sourceChanged
                    }
                    switch mutation {
                    case .copy(let destination):
                        // copyfile calls back only while it runs, so the closure never outlives this call.
                        try withoutActuallyEscaping(progress) { progress in
                            try NativeMutation.copy(from: source, to: destination, cancellation: cancellation, progress: progress)
                        }
                        return destination
                    case .move(let destination):
                        try NativeMutation.publish(source, as: destination)
                        return destination
                    case .trash:
                        do { return try trash(source) } catch { throw FileSystemError.mapping(error) }
                    }
                }
            } onCancel: { cancellation.cancel() }
        } catch is CancellationError {
            // IOExecutor only throws this before the body is admitted, so nothing happened.
            throw ConditionalMutationError.cancelledBeforeMutation
        }
        #else
        throw ConditionalMutationError.unsupported
        #endif
    }
    public func entry(at url: URL) async throws -> FileEntry {
        try await executor.runRead(volume: queueKey(url)) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let volume = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? queueKey(url)
                return try readMetadata(url, true, volume)
            } catch { throw FileSystemError.mapping(error) }
        }
    }
    public func exists(_ url: URL) async -> Bool { (try? await entry(at: url)) != nil }
    private func perform(at url: URL, also others: [URL] = [], _ body: @escaping @Sendable (FileManager) throws -> Void) async throws {
        try await executor.run(volumes: ([url] + others).map(queueKey)) {
            do { try body(FileManager.default) } catch { throw FileSystemError.mapping(error) }
        }
    }
    public func copyItem(at source: URL, to destination: URL) async throws {
        try await perform(at: source, also: [destination]) { try $0.copyItem(at: source, to: destination) }
    }
    public func moveItem(at source: URL, to destination: URL) async throws {
        try await perform(at: source, also: [destination]) { try $0.moveItem(at: source, to: destination) }
    }
    public func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws {
        try await perform(at: destination, also: [temporary, backup]) { manager in
            try manager.moveItem(at: destination, to: backup)
            do { try manager.moveItem(at: temporary, to: destination) }
            catch {
                do { try manager.moveItem(at: backup, to: destination) }
                catch { throw FileSystemError.other("Replacement failed; original retained at \(backup.path)") }
                throw error
            }
        }
    }
    public func applyDirectoryMetadata(from source: URL, to destination: URL) async throws {
        try await perform(at: destination, also: [source]) { manager in
            let sourceAttributes = try manager.attributesOfItem(atPath: source.path)
            var attributes: [FileAttributeKey: Any] = [:]
            for key: FileAttributeKey in [.posixPermissions, .modificationDate, .creationDate] {
                attributes[key] = sourceAttributes[key]
            }
            try manager.setAttributes(attributes, ofItemAtPath: destination.path)
        }
    }
    public func trashItem(at url: URL) async throws -> URL? {
        #if os(macOS)
        let trash = self.trash
        return try await executor.run(volume: queueKey(url)) {
            do { return try trash(url) } catch { throw FileSystemError.mapping(error) }
        }
        #else
        throw FileSystemError.unsupported
        #endif
    }
    public func removeItem(at url: URL) async throws { try await perform(at: url) { try $0.removeItem(at: url) } }
    // These synchronous create bodies never throw CancellationError. IOExecutor only
    // emits it before body admission, so callers can safely retain prefix undo (B-038).
    private func runCreate(at url: URL, _ body: @escaping @Sendable () throws -> Void) async throws {
        do { try await executor.run(volume: queueKey(url), body) }
        catch is CancellationError { throw ConditionalMutationError.cancelledBeforeMutation }
    }
    public func createDirectory(at url: URL) async throws {
        try await runCreate(at: url) {
            guard mkdir(url.path, mode_t(0o777)) == 0 else {
                let code = errno
                if code == EEXIST { throw FileSystemError.collision(noMutation: true) }
                throw FileSystemError.mapping(NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
            }
        }
    }
    public func createFileExclusively(at url: URL, contents: Data) async throws {
        try await runCreate(at: url) {
            try Self.writeExclusively(at: url, contents: contents)
        }
    }
    // Internal syscall seam permits deterministic ownership-race regression tests.
    static func writeExclusively(at url: URL, contents: Data,
        writeBytes: (Int32, UnsafeRawPointer, Int) throws -> Int = { write($0, $1, $2) }) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o666))
        guard descriptor >= 0 else {
            let code = errno
            if code == EEXIST { throw FileSystemError.collision(noMutation: true) }
            throw FileSystemError.mapping(NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
        }
        defer { _ = close(descriptor) }
        do {
            try contents.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    guard let base = bytes.baseAddress else { return }
                    let count = try writeBytes(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    offset += count
                }
            }
        } catch {
            // Retain partial artifacts: the pathname may now belong to another writer.
            throw FileSystemError.mapping(error)
        }
    }
    public func createSymbolicLink(at url: URL, destination: URL) async throws {
        try await perform(at: url) { try $0.createSymbolicLink(at: url, withDestinationURL: destination) }
    }
    public func createAlias(for url: URL, at destination: URL) async throws {
        #if os(macOS)
        try await executor.run(volumes: [queueKey(url), queueKey(destination)]) {
            do {
                let data = try url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                // writeBookmarkData replaces silently: reserve the name so EEXIST arbitrates keep-both (B-038).
                // On a later write failure the placeholder is retained, like any partial exclusive write.
                try Self.writeExclusively(at: destination, contents: Data())
                try URL.writeBookmarkData(data, to: destination)
            } catch { throw FileSystemError.mapping(error) }
        }
        #else
        throw FileSystemError.unsupported
        #endif
    }
    /// Queries volume metadata only; Linux uses case-sensitive path semantics (F-052/B-039).
    public func isCaseSensitive(at url: URL) async throws -> Bool {
        #if os(macOS)
        return try await executor.runRead(volume: queueKey(url)) {
            try url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? false
        }
        #else
        return true
        #endif
    }
    public func volumeIdentifier(for url: URL) async throws -> String {
        try await executor.runRead(volume: queueKey(url)) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.systemNumber] as? NSNumber)?.stringValue ?? "/"
        }
    }
    public func availableCapacity(of url: URL) async throws -> Int64 {
        try await executor.runRead(volume: queueKey(url)) {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
            guard let value = attributes[.systemFreeSize] as? NSNumber else { throw FileSystemError.unsupported }
            return value.int64Value
        }
    }
}
