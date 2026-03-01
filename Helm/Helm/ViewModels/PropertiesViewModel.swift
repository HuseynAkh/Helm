import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine

@MainActor
final class PropertiesViewModel: ObservableObject {

    @Published var fileName: String = ""
    @Published var fileURL: URL?
    @Published var icon: NSImage?
    @Published var kind: String = ""
    @Published var size: String = ""
    @Published var sizeInBytes: String = ""
    @Published var location: String = ""
    @Published var createdDate: String = ""
    @Published var modifiedDate: String = ""
    @Published var contentType: String = ""

    // Image-specific
    @Published var imageDimensions: String?

    // Permissions
    @Published var ownerPermissions: String = ""
    @Published var groupPermissions: String = ""
    @Published var otherPermissions: String = ""
    @Published var posixPermissions: String = ""

    // Open with
    @Published var defaultApplication: String = ""
    @Published var availableApplications: [URL] = []

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .medium
        return f
    }()

    func load(url: URL) {
        fileURL = url
        fileName = url.lastPathComponent
        icon = NSWorkspace.shared.icon(forFile: url.path)
        icon?.size = NSSize(width: 64, height: 64)
        location = url.deletingLastPathComponent().path

        // Basic attributes
        do {
            let keys: Set<URLResourceKey> = [
                .fileSizeKey, .totalFileSizeKey, .contentTypeKey,
                .creationDateKey, .contentModificationDateKey, .isDirectoryKey
            ]
            let values = try url.resourceValues(forKeys: keys)

            let bytes = Int64(values.totalFileSize ?? values.fileSize ?? 0)
            size = FileSizeFormatter.format(bytes)
            sizeInBytes = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)

            if let ct = values.contentType {
                kind = ct.localizedDescription ?? ct.identifier
                contentType = ct.identifier
            }

            if let created = values.creationDate {
                createdDate = Self.dateFormatter.string(from: created)
            }
            if let modified = values.contentModificationDate {
                modifiedDate = Self.dateFormatter.string(from: modified)
            }
        } catch {}

        // POSIX permissions
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let posix = attrs[.posixPermissions] as? Int {
                posixPermissions = String(posix, radix: 8)
                ownerPermissions = permissionString((posix >> 6) & 0x7)
                groupPermissions = permissionString((posix >> 3) & 0x7)
                otherPermissions = permissionString(posix & 0x7)
            }
        } catch {}

        // Image dimensions
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                if let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                   let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
                    imageDimensions = "\(width) × \(height) pixels"
                }
            }
        }

        // Default app
        if let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) {
            defaultApplication = appURL.deletingPathExtension().lastPathComponent
        }
        availableApplications = NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    private func permissionString(_ bits: Int) -> String {
        var result = ""
        result += (bits & 0x4) != 0 ? "Read" : ""
        if (bits & 0x2) != 0 {
            result += result.isEmpty ? "Write" : ", Write"
        }
        if (bits & 0x1) != 0 {
            result += result.isEmpty ? "Execute" : ", Execute"
        }
        return result.isEmpty ? "None" : result
    }
}
