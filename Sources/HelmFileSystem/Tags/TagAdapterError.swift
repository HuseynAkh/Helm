// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Metadata failures stay visible without modifying Helm stars (F-029, B-039).
public enum TagAdapterError: Error, Equatable, Sendable {
    case unsupportedFilesystem, permissionDenied, notFound, conflict, invalidPath
    case system(Int32)

    public static func fromPOSIX(_ code: Int32) -> TagAdapterError {
        // Darwin can distinguish ENOTSUP from EOPNOTSUPP; Linux aliases them.
        if code == EOPNOTSUPP { return .unsupportedFilesystem }
        switch code {
        case ENOTSUP, ENOSYS: return .unsupportedFilesystem
        case EACCES, EPERM, EROFS: return .permissionDenied
        case ENOENT, ENOTDIR: return .notFound
        default: return .system(code)
        }
    }
}

protocol TagAttributeAccess: Sendable {
    func read(path: String, name: String) throws -> Data?
    func write(path: String, name: String, data: Data) throws
    func remove(path: String, name: String) throws
    func names(path: String) throws -> [String]
}
