import Foundation
import HelmCore

/// One app chosen to open one kind of file, and when.
public struct OpenWithRecord: Codable, Equatable, Sendable {
    public let contentType: String
    /// The app's path.
    public let application: String
    public let lastUsed: Date
    public init(contentType: String, application: String, lastUsed: Date) {
        self.contentType = contentType; self.application = application; self.lastUsed = lastUsed
    }
}

/// Which apps you've opened each kind of file with, newest first, so Open With can offer them before the rest.
/// It's Helm's own memory: macOS keeps no such list. Without a file it lives in memory only (fixture runs, tests).
@MainActor public final class OpenWithStore: AppFlushable {
    public static let perTypeLimit = 6
    public static let totalLimit = 600
    private let file: JSONFileStore<[OpenWithRecord]>?
    private var memory: [OpenWithRecord] = []
    public var records: [OpenWithRecord] { file?.items ?? memory }

    public init() { file = nil }
    public init(url: URL) async throws {
        let file = JSONFileStore<[OpenWithRecord]>(url: url, empty: [])
        try await file.load()
        self.file = file
    }

    /// App paths used for this kind of file, most recent first.
    public func recentApplications(for contentType: String) -> [String] {
        records.filter { $0.contentType == contentType }.sorted { $0.lastUsed > $1.lastUsed }.map(\.application)
    }

    public func recordUse(of application: String, for contentType: String, at date: Date) {
        var next = records.filter { !($0.contentType == contentType && $0.application == application) }
        next.append(OpenWithRecord(contentType: contentType, application: application, lastUsed: date))
        // Keep the newest few per kind, and a bounded file overall.
        let sameType = next.filter { $0.contentType == contentType }.sorted { $0.lastUsed > $1.lastUsed }
        let dropped = Set(sameType.dropFirst(Self.perTypeLimit).map(\.application))
        next.removeAll { $0.contentType == contentType && dropped.contains($0.application) }
        if next.count > Self.totalLimit { next = Array(next.sorted { $0.lastUsed > $1.lastUsed }.prefix(Self.totalLimit)) }
        if let file { file.replace(with: next) } else { memory = next }
    }

    public func flush() async throws { try await file?.flush() }
}
