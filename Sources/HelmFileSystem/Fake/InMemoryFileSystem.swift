// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Deterministic fake supports case-insensitive collisions, access failures and link cycles (B-039, B-109).
public actor InMemoryFileSystem: FileSystem {
    private struct Node: Sendable {
        var identity = UUID()
        var url: URL
        var kind: FileEntryKind
        var data: Data
        var target: URL?
        var modified: Date
    }
    private var nodes: [String: Node] = [:]
    private var failures: [String: FileSystemError] = [:]
    private let caseSensitive: Bool
    private let volumeIDs: [URL: String]
    private let identityScope = UUID().uuidString
    private var tick: TimeInterval = 0
    private var latencyNanoseconds: UInt64 = 0
    private var capacity = Int64.max
    public init(caseSensitive: Bool = true) {
        self.init(caseSensitive: caseSensitive, volumeIDs: [:])
    }
    /// Inject mount prefixes to exercise cross-volume move refusal (F-052/B-039).
    public init(caseSensitive: Bool = true, volumeIDs: [URL: String]) {
        self.volumeIDs = volumeIDs
        self.caseSensitive = caseSensitive
        nodes["/"] = Node(url: URL(fileURLWithPath: "/"), kind: .directory, data: Data(), modified: .distantPast)
    }
    private func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        // Share planning's oracle; native filesystems can still differ, so EEXIST
        // remains the final collision arbiter for live mutations (B-039).
        return caseSensitive ? path : FileNameComparison.key(path, caseSensitive: false)
    }
    public func setLatency(nanoseconds: UInt64) { latencyNanoseconds = nanoseconds }
    private func delay() async throws {
        try Task.checkCancellation()
        if latencyNanoseconds > 0 { try await Task.sleep(nanoseconds: latencyNanoseconds) }
    }
    public func setFailure(_ error: FileSystemError?, at url: URL) { failures[key(url)] = error }
    private func check(_ url: URL) throws {
        var current = url.standardizedFileURL
        while true {
            if let failure = failures[key(current)] { throw failure }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
    }
    private func node(_ url: URL) throws -> Node {
        try check(url)
        guard let value = nodes[key(url)] else { throw FileSystemError.notFound }
        return value
    }
    private func resolved(_ url: URL, visited: Set<String> = []) throws -> Node {
        let path = key(url)
        guard !visited.contains(path) else { throw FileSystemError.notFound }
        let value = try node(url)
        if let target = value.target { return try resolved(target, visited: visited.union([path])) }
        return value
    }
    private func entry(_ value: Node, resolve: Bool = true) -> FileEntry {
        var kind = value.kind
        if let target = value.target {
            if resolve, let targetNode = try? resolved(target) {
                kind = targetNode.kind == .directory ? .symlinkToDirectory : .symlinkToFile
            } else { kind = .danglingSymlink }
        }
        return FileEntry(url: value.url, kind: kind, isHidden: value.url.lastPathComponent.hasPrefix("."),
                         size: Int64(value.data.count), modificationDate: value.modified, volumeIdentifier: volumeID(for: value.url),
                         objectIdentity: FileObjectIdentity(scope: identityScope, object: value.identity.uuidString))
    }
    public func entry(at url: URL) async throws -> FileEntry { try await delay(); return entry(try node(url)) }
    // Internal fixture reader enables payload fidelity assertions without expanding FileSystem.
    func storedContents(at url: URL) throws -> Data { try node(url).data }
    public func exists(_ url: URL) async -> Bool { (try? node(url)) != nil }
    private func listing(_ directory: URL, options: EnumerationOptions) throws -> [FileEntry] {
        let parent = try resolved(directory)
        guard parent.kind == .directory || parent.kind == .package else { throw FileSystemError.other("Not a directory") }
        let parentKey = key(parent.url)
        return nodes.values.filter {
            key($0.url) != parentKey && key($0.url.deletingLastPathComponent()) == parentKey
        }.map { value in
            var display = value
            display.url = directory.appendingPathComponent(value.url.lastPathComponent)
            return entry(display, resolve: options.resolveSymlinkTargets)
        }.filter { options.includeHidden || !$0.isHidden }.sorted { $0.name < $1.name }
    }
    public nonisolated func enumerate(_ directory: URL, options: EnumerationOptions = EnumerationOptions()) -> AsyncThrowingStream<[FileEntry], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    try await delay()
                    let values = try await listing(directory, options: options)
                    for start in stride(from: 0, to: values.count, by: max(1, options.batchSize)) {
                        try Task.checkCancellation()
                        continuation.yield(Array(values[start..<min(start + max(1, options.batchSize), values.count)]))
                        await Task.yield()
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func insert(_ url: URL, kind: FileEntryKind, data: Data = Data(), target: URL? = nil) throws {
        try check(url)
        guard nodes[key(url)] == nil else { throw FileSystemError.collision(noMutation: true) }
        let parent = try node(url.deletingLastPathComponent())
        guard parent.kind == .directory else { throw FileSystemError.other("Not a directory") }
        tick += 1
        nodes[key(url)] = Node(url: url, kind: kind, data: data, target: target, modified: Date(timeIntervalSince1970: tick))
        nodes[key(parent.url)]?.modified = Date(timeIntervalSince1970: tick)
    }
    public func createDirectory(at url: URL) async throws {
        if Task.isCancelled { throw ConditionalMutationError.cancelledBeforeMutation }
        try insert(url, kind: .directory)
    }
    public func createFileExclusively(at url: URL, contents: Data) async throws {
        if Task.isCancelled { throw ConditionalMutationError.cancelledBeforeMutation }
        try insert(url, kind: .regular, data: contents)
    }
    public func createSymbolicLink(at url: URL, destination: URL) async throws { try insert(url, kind: .danglingSymlink, target: destination) }
    public func createAlias(for url: URL, at destination: URL) async throws { _ = try node(url); try insert(destination, kind: .alias) }
    public func removeItem(at url: URL) async throws {
        _ = try node(url)
        guard key(url) != "/" else { throw FileSystemError.permissionDenied }
        let path = key(url)
        nodes = nodes.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        tick += 1
        nodes[key(url.deletingLastPathComponent())]?.modified = Date(timeIntervalSince1970: tick)
    }
    public func copyItem(at source: URL, to destination: URL) async throws { try copy(source, to: destination) }
    private func copy(_ source: URL, to destination: URL) throws {
        let root = try node(source)
        let sourceKey = key(source)
        guard key(destination) != sourceKey && !key(destination).hasPrefix(sourceKey + "/") else {
            throw FileSystemError.other("Recursive destination")
        }
        let descendants = nodes.values.filter { key($0.url).hasPrefix(sourceKey + "/") }
        try insert(destination, kind: root.kind, data: root.data, target: root.target)
        for child in descendants.sorted(by: { $0.url.path.count < $1.url.path.count }) {
            let suffix = String(child.url.path.dropFirst(root.url.path.count + 1))
            do { try insert(destination.appendingPathComponent(suffix), kind: child.kind, data: child.data, target: child.target) }
            catch FileSystemError.collision { throw FileSystemError.collision(noMutation: false) }
        }
    }
    public func moveItem(at source: URL, to destination: URL) async throws {
        try move(source, to: destination)
    }
    private func move(_ source: URL, to destination: URL) throws {
        let root = try node(source); try check(destination)
        let sourceKey = key(source), targetKey = key(destination)
        guard sourceKey != "/", targetKey != sourceKey, !targetKey.hasPrefix(sourceKey + "/") else {
            throw FileSystemError.other("Recursive destination")
        }
        guard nodes[targetKey] == nil else { throw FileSystemError.collision(noMutation: true) }
        guard try node(destination.deletingLastPathComponent()).kind == .directory else {
            throw FileSystemError.other("Not a directory")
        }
        let moved = nodes.filter { $0.key == sourceKey || $0.key.hasPrefix(sourceKey + "/") }
        for (oldKey, var value) in moved {
            nodes.removeValue(forKey: oldKey)
            let suffix = String(value.url.path.dropFirst(root.url.path.count))
            value.url = URL(fileURLWithPath: destination.path + suffix)
            nodes[key(value.url)] = value
        }
        tick += 1
        for parent in [source.deletingLastPathComponent(), destination.deletingLastPathComponent()] {
            nodes[key(parent)]?.modified = Date(timeIntervalSince1970: tick)
        }
    }
    public func mutationPrecondition(at source: URL) async throws -> FileMutationPrecondition {
        try evidence(source)
    }
    private func evidence(_ source: URL) throws -> FileMutationPrecondition {
        let value = try node(source), metadata = entry(try node(source))
        return FileMutationPrecondition(identity: FileObjectIdentity(scope: identityScope, object: value.identity.uuidString),
                                        changeToken: metadata.changeToken, kind: metadata.kind)
    }
    /// No await between comparison, destination admission and mutation: actor isolation is atomic here.
    public func mutate(_ mutation: ConditionalFileMutation, source: URL,
                       requiring precondition: FileMutationPrecondition) async throws -> URL? {
        if Task.isCancelled { throw ConditionalMutationError.cancelledBeforeMutation }
        guard try evidence(source) == precondition else { throw ConditionalMutationError.sourceChanged }
        switch mutation {
        case .move(let destination): try move(source, to: destination); return destination
        case .copy(let destination): try copy(source, to: destination); return destination
        case .trash: return try trash(source)
        }
    }
    public func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws {
        try await moveItem(at: destination, to: backup)
        do { try await moveItem(at: temporary, to: destination) }
        catch {
            let original = error
            do { try await moveItem(at: backup, to: destination) }
            catch FileSystemError.collision { throw FileSystemError.collision(noMutation: false) }
            if case FileSystemError.collision = original { throw FileSystemError.collision(noMutation: false) }
            throw original
        }
    }
    public func applyDirectoryMetadata(from source: URL, to destination: URL) async throws {
        let original = try node(source); _ = try node(destination)
        nodes[key(destination)]?.modified = original.modified
    }
    public func trashItem(at url: URL) async throws -> URL? { try trash(url) }
    private func trash(_ url: URL) throws -> URL {
        let trash = URL(fileURLWithPath: "/.Trash")
        if nodes[key(trash)] == nil { try insert(trash, kind: .directory) }
        var destination = trash.appendingPathComponent(url.lastPathComponent)
        var index = 1
        while nodes[key(destination)] != nil {
            destination = trash.appendingPathComponent(url.lastPathComponent + ".\(index)"); index += 1
        }
        try move(url, to: destination)
        return destination
    }
    /// Fake volume capability matches its actual name lookup mode (F-052/B-039).
    public func isCaseSensitive(at url: URL) async throws -> Bool { caseSensitive }
    private func volumeID(for url: URL) -> String {
        volumeIDs.sorted { $0.key.path.count > $1.key.path.count }.first {
            url.path == $0.key.path || url.path.hasPrefix($0.key.path + "/")
        }?.value ?? "memory"
    }
    public func volumeIdentifier(for url: URL) async throws -> String { _ = try node(url); return volumeID(for: url) }
    public func availableCapacity(of url: URL) async throws -> Int64 { _ = try node(url); return capacity }
    /// What `availableCapacity` reports from now on, as a disk filling up or emptying would.
    public func setAvailableCapacity(_ bytes: Int64) { capacity = bytes }
    /// Bulk fixture setup avoids actor hops while retaining ordinary collision checks (F-035).
    public func seedFiles(in directory: URL, count: Int) throws {
        for index in 0..<max(0, count) { try insert(directory.appendingPathComponent("file\(index)"), kind: .regular) }
    }
}
