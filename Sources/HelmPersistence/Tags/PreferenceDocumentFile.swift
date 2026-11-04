// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Explicit recovery state for preference documents (F-065, B-029).
public enum PreferenceDocumentError: Error, Equatable, Sendable {
    case recoveryReadOnly
    case invalidTagName
    case duplicateTagName
    case tagNotFound
    case invalidOrder
}

/// Serializes disk access and never authorizes writes after a failed read.
internal actor PreferenceDocumentFile<Value: Codable & Sendable> {
    private let url: URL
    private var writable: Bool = false
    private var savedRevision: UInt64 = 0
    init(url: URL) { self.url = url }

    func load(defaults: Value, decode: @Sendable (Data) throws -> Value) throws -> (Value, URL?) {
        writable = false
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            let failure = error as NSError
            let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            let missing = failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileReadNoSuchFile.rawValue
            let otherCause = underlying?.domain == NSPOSIXErrorDomain && underlying?.code != 2
            guard missing && !otherCause else { throw error }
            writable = true
            return (defaults, nil)
        }
        do {
            let value = try decode(data)
            writable = true
            return (value, nil)
        } catch is DecodingError {
            let backup = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
            try data.write(to: backup, options: .atomic)
            return (defaults, backup)
        }
    }

    func save(_ value: Value, revision: UInt64) throws {
        guard writable else { throw PreferenceDocumentError.recoveryReadOnly }
        guard revision >= savedRevision else { return }
        let data = try JSONEncoder().encode(VersionedDocument(items: value))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        savedRevision = revision
    }
}

internal struct PreferenceDocumentHeader: Decodable { let schemaVersion: Int }
