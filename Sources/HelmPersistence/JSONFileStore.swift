// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Atomic, serialized disk work stays off the main actor (F-028–F-030, B-029).
private actor JSONDisk<Payload: Codable & Sendable> {
    let url: URL
    var lastRevision: UInt64 = 0
    let read: @Sendable (URL) async throws -> Data
    init(url: URL, read: @escaping @Sendable (URL) async throws -> Data = { try Data(contentsOf: $0) }) {
        self.url = url; self.read = read
    }
    func load(empty: Payload, recoverCorruption: Bool) async throws -> Payload {
        let data: Data
        do { data = try await read(url) }
        catch {
            let failure = error as NSError
            // Only a definite missing file authorizes creation. ENOTDIR/EACCES/IO fail closed.
            let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            let isMissing = failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileReadNoSuchFile.rawValue
            let hasOtherPOSIXCause = underlying?.domain == NSPOSIXErrorDomain && underlying?.code != 2
            if isMissing && !hasOtherPOSIXCause {
                return empty
            }
            throw error
        }
        do {
            do {
                let header = try JSONDecoder().decode(DocumentHeader.self, from: data)
                guard header.schemaVersion == 1 else { throw PersistenceError.unsupportedVersion(header.schemaVersion) }
            }
            return try JSONDecoder().decode(VersionedDocument<Payload>.self, from: data).items
        } catch let error as DecodingError {
            guard recoverCorruption else { throw error }
            // Copy before permitting an empty state; if backup fails, propagate the error.
            let stamp = String(Int(Date().timeIntervalSince1970))
            let backup = url.appendingPathExtension("corrupt-\(stamp)-\(UUID().uuidString)")
            try data.write(to: backup, options: .atomic)
            return empty
        }
    }
    func save(_ payload: Payload, revision: UInt64) throws {
        guard revision >= lastRevision else { return }
        let data = try JSONEncoder().encode(VersionedDocument(items: payload))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        lastRevision = revision
    }
    /// Deletes the file. A file that's already gone is fine.
    func remove(revision: UInt64) throws {
        guard revision >= lastRevision else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile {}
        lastRevision = revision
    }
}
private struct DocumentHeader: Decodable { let schemaVersion: Int }

/// Main-actor state with 500 ms debouncing, explicit flush, and observable failures (F-028–F-030).
/// Call load before editing; loading an unsupported schema makes the instance read-only.
@MainActor public final class JSONFileStore<Payload: Codable & Sendable> {
    public private(set) var items: Payload
    public private(set) var lastError: (any Error)?
    public let changes: Broadcast<Payload> = Broadcast()
    private let disk: JSONDisk<Payload>
    private let empty: Payload
    private var revision: UInt64 = 0
    private var persistedRevision: UInt64 = 0
    private var loading: Bool = false
    private var pending: Task<Void, Never>?
    private var writable: Bool = false
    /// The file was deleted on purpose, and nothing has changed since: saving then writes nothing.
    private var removed: Bool = false
    public init(url: URL, empty: Payload) { self.items = empty; self.empty = empty; self.disk = JSONDisk(url: url) }
    // Internal read seam permits permission/IO regression tests without privileged filesystem assumptions.
    init(url: URL, empty: Payload, read: @escaping @Sendable (URL) async throws -> Data) {
        self.items = empty; self.empty = empty; self.disk = JSONDisk(url: url, read: read)
    }
    public func load(recoverCorruption: Bool = true) async throws {
        guard !loading, revision == persistedRevision else { throw PersistenceError.modifiedDuringLoad }
        loading = true
        defer { loading = false }
        let before = revision
        do {
            let loaded = try await disk.load(empty: empty, recoverCorruption: recoverCorruption)
            guard before == revision else { throw PersistenceError.modifiedDuringLoad }
            items = loaded; writable = true; lastError = nil; changes.send(items)
        } catch { writable = false; lastError = error; throw error }
    }
    public func replace(with value: Payload) {
        guard writable, !loading else { return }
        items = value; revision &+= 1; removed = false
        let current = revision
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self, self.revision == current else { return }
            do { try await self.flush() } catch { self.lastError = error }
        }
        changes.send(items)
    }
    /// Empties the document and deletes its file straight away, for a record Settings says not to keep.
    /// Saving writes nothing until the next change, which writes the file again.
    public func remove() {
        guard writable, !loading, !removed else { return }
        items = empty; revision &+= 1; removed = true
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            do { try await self.flush() } catch { self.lastError = error }
        }
        changes.send(items)
    }
    public func flush() async throws {
        guard !loading else { throw PersistenceError.modifiedDuringLoad }
        pending?.cancel(); pending = nil
        guard writable else {
            if let lastError { throw lastError }
            throw PersistenceError.modifiedDuringLoad
        }
        let current = revision
        do {
            if removed { try await disk.remove(revision: current) } else { try await disk.save(items, revision: current) }
            persistedRevision = max(persistedRevision, current)
            if revision == current { lastError = nil }
        } catch { lastError = error; throw error }
    }
}
