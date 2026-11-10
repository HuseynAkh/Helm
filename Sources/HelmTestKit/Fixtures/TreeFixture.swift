import Foundation
import HelmCore

/// Pure listing fixtures for F-035 and F-040; does not perform filesystem mutations.
public struct TreeFixture: Sendable {
    public let root: URL
    public init(root: URL = URL(fileURLWithPath: "/fixture", isDirectory: true)) { self.root = root }
    public func file(_ name: String, size: Int64 = 0) -> FileEntry {
        FileEntry(url: root.appendingPathComponent(name), size: size)
    }
    public func directory(_ name: String) -> FileEntry {
        FileEntry(url: root.appendingPathComponent(name, isDirectory: true), kind: .directory)
    }
}
