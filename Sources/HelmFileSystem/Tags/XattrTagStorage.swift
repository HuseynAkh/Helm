// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Lossless per-tag metadata edits preserve unknown entries and private stars (F-029, M18).
/// Comparison detects intervening writes, but the OS offers no atomic xattr compare-and-swap.
public actor XattrTagStorage: TagStorage {
    #if os(Linux)
    public static let attributeName: String = "user." + FinderTagCodec.attributeName
    #else
    public static let attributeName: String = FinderTagCodec.attributeName
    #endif
    private static let mutationLock = NSLock()
    private let access: any TagAttributeAccess
    public init() { access = NativeTagAttributes() }
    init(access: any TagAttributeAccess) { self.access = access }

    private func path(for item: ItemID) throws -> String {
        guard !item.rawValue.utf8.contains(0), item.rawValue.hasPrefix("/") else {
            throw TagAdapterError.invalidPath
        }
        return item.rawValue
    }

    public func tags(for item: ItemID) throws -> TagSet {
        let data = try access.read(path: path(for: item), name: Self.attributeName)
        return try data.map(FinderTagCodec.decode) ?? TagSet()
    }

    public func apply(_ edit: TagEdit, to item: ItemID) throws {
        // No suspension inside the lock: serialize all adapter instances in this process.
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let path = try path(for: item)
        for _ in 0..<3 {
            let original = try access.read(path: path, name: Self.attributeName)
            let current = try original.map(FinderTagCodec.decode) ?? TagSet()
            let updated = edit.applying(to: current)
            guard updated != current else { return }
            guard try access.read(path: path, name: Self.attributeName) == original else { continue }
            if updated.tags.isEmpty {
                try access.remove(path: path, name: Self.attributeName)
            } else {
                try access.write(path: path, name: Self.attributeName, data: FinderTagCodec.encode(updated))
            }
            return
        }
        throw TagAdapterError.conflict
    }
}
