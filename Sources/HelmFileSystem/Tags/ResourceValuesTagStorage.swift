// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
#if os(macOS)
import Foundation
import HelmCore

/// Name-only provider reads keep Finder tags separate from Helm stars (F-029, M18).
/// Mutations use the lossless xattr adapter because tagNamesKey cannot round-trip unknown colors.
// MAC-VERIFY: compile and compare provider names with Finder on an approved macOS fixture.
public struct ResourceValuesTagStorage: TagStorage {
    private let writer: XattrTagStorage
    public init(writer: XattrTagStorage = XattrTagStorage()) { self.writer = writer }
    public func tags(for item: ItemID) async throws -> TagSet {
        do {
            let values = try item.url.resourceValues(forKeys: [.tagNamesKey])
            return TagSet(tags: (values.tagNames ?? []).map { FinderTag(rawValue: $0) })
        } catch let error as NSError {
            if error.domain == NSPOSIXErrorDomain { throw TagAdapterError.fromPOSIX(Int32(error.code)) }
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError: throw TagAdapterError.notFound
                case NSFileReadNoPermissionError: throw TagAdapterError.permissionDenied
                case NSFeatureUnsupportedError: throw TagAdapterError.unsupportedFilesystem
                default: break
                }
            }
            throw error
        }
    }
    public func apply(_ edit: TagEdit, to item: ItemID) async throws {
        try await writer.apply(edit, to: item)
    }
}
#endif
