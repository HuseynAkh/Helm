// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
// swift Glibc omits sys/xattr.h. These declarations match Linux libc's C ABI:
// ssize_t/size_t are Int on supported Swift hosts; flags are C int (Int32).
@_silgen_name("getxattr") private func linuxGet(_ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>, _ data: UnsafeMutableRawPointer?, _ size: Int) -> Int
@_silgen_name("setxattr") private func linuxSet(_ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>, _ data: UnsafeRawPointer?, _ size: Int, _ flags: Int32) -> Int32
@_silgen_name("removexattr") private func linuxRemove(_ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>) -> Int32
@_silgen_name("listxattr") private func linuxList(_ path: UnsafePointer<CChar>, _ data: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int
#endif

struct NativeTagAttributes: TagAttributeAccess {
    private func get(_ path: String, _ name: String, _ pointer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        // Darwin position=0 and options=0 follow symlinks, as Foundation resource values do.
        return Darwin.getxattr(path, name, pointer, count, 0, 0)
        #elseif canImport(Glibc)
        return linuxGet(path, name, pointer, count)
        #else
        return -1
        #endif
    }

    func read(path: String, name: String) throws -> Data? {
        for _ in 0..<3 {
            let count = get(path, name, nil, 0)
            if count < 0 {
                #if canImport(Darwin)
                if errno == ENOATTR { return nil }
                #elseif canImport(Glibc)
                if errno == ENODATA { return nil }
                #endif
                throw TagAdapterError.fromPOSIX(errno)
            }
            // Bound allocation even on a faulty network filesystem.
            guard count <= 16 * 1024 * 1024 else { throw TagAdapterError.system(E2BIG) }
            var data = Data(count: max(count, 1))
            let actual = data.withUnsafeMutableBytes { get(path, name, $0.baseAddress, $0.count) }
            if actual < 0 {
                if errno == ERANGE { continue }
                throw TagAdapterError.fromPOSIX(errno)
            }
            data.count = actual
            return data
        }
        throw TagAdapterError.conflict
    }

    func write(path: String, name: String, data: Data) throws {
        let result: Int32 = data.withUnsafeBytes { buffer in
            #if canImport(Darwin)
            // Position zero; options zero creates or replaces this attribute only.
            return Darwin.setxattr(path, name, buffer.baseAddress, buffer.count, 0, 0)
            #elseif canImport(Glibc)
            return linuxSet(path, name, buffer.baseAddress, buffer.count, 0)
            #else
            return -1
            #endif
        }
        if result != 0 { throw TagAdapterError.fromPOSIX(errno) }
    }

    func remove(path: String, name: String) throws {
        #if canImport(Darwin)
        let result = Darwin.removexattr(path, name, 0) // options zero follows symlinks.
        #elseif canImport(Glibc)
        let result = linuxRemove(path, name)
        #else
        let result: Int32 = -1
        #endif
        if result != 0 { throw TagAdapterError.fromPOSIX(errno) }
    }

    func names(path: String) throws -> [String] {
        func list(_ pointer: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int {
            #if canImport(Darwin)
            return Darwin.listxattr(path, pointer, size, 0) // options zero follows symlinks.
            #elseif canImport(Glibc)
            return linuxList(path, pointer, size)
            #else
            return -1
            #endif
        }
        for _ in 0..<3 {
            let count = list(nil, 0)
            guard count >= 0 else { throw TagAdapterError.fromPOSIX(errno) }
            guard count <= 16 * 1024 * 1024 else { throw TagAdapterError.system(E2BIG) }
            var bytes = [CChar](repeating: 0, count: max(count, 1))
            let actual = bytes.withUnsafeMutableBufferPointer { list($0.baseAddress, $0.count) }
            if actual < 0 {
                if errno == ERANGE { continue }
                throw TagAdapterError.fromPOSIX(errno)
            }
            return bytes.prefix(actual).split(separator: 0).map {
                String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        throw TagAdapterError.conflict
    }
}
