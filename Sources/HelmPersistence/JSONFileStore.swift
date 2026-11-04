import Foundation
import HelmCore

/// Atomic, serialized disk work stays off the main actor (F-028–F-030, B-029).
private actor JSONDisk<Payload: Codable & Sendable> {
    let url: URL
    var lastRevision: UInt64 = 0
    init(url: URL) { self.url = url }
    func load(empty: Payload, recoverCorruption: Bool) throws -> Payload {
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        let data = try Data(contentsOf: url)
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
    private var pending: Task<Void, Never>?
    private var writable: Bool = false
    public init(url: URL, empty: Payload) { self.items = empty; self.empty = empty; self.disk = JSONDisk(url: url) }
    public func load(recoverCorruption: Bool = true) async throws {
        let before = revision
        do {
            let loaded = try await disk.load(empty: empty, recoverCorruption: recoverCorruption)
            guard before == revision else { throw PersistenceError.modifiedDuringLoad }
            items = loaded; writable = true; lastError = nil; changes.send(items)
        } catch { writable = false; lastError = error; throw error }
    }
    public func replace(with value: Payload) {
        guard writable else { return }
        items = value; revision &+= 1
        let current = revision
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self, self.revision == current else { return }
            do { try await self.flush() } catch { self.lastError = error }
        }
        changes.send(items)
    }
    public func flush() async throws {
        pending?.cancel(); pending = nil
        guard writable else {
            if let lastError { throw lastError }
            throw PersistenceError.modifiedDuringLoad
        }
        let current = revision
        do {
            try await disk.save(items, revision: current)
            if revision == current { lastError = nil }
        } catch { lastError = error; throw error }
    }
}
