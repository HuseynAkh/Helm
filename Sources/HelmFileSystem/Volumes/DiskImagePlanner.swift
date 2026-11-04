// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Planned P-204 image attach extends F-007; encrypted images remain system credential UI work.
public struct DiskImageAttachPlan: Equatable, Sendable {
    public let image: URL
    public let command: ArchiveCommand
    public init(image: URL, command: ArchiveCommand) { self.image = image; self.command = command }
}

/// Typed attach completion for F-007/P-204; process success alone does not prove a mount.
public enum DiskImageAttachResult: Equatable, Sendable {
    case mounted([URL])
    case cancelled
    case failed(code: Int32, diagnostic: String)
    case invalidResponse
}

/// Builds hdiutil arguments and decodes its plist without execution (F-007, P-204/P-315).
public enum DiskImagePlanner {
    public static func attach(image: URL, readOnly: Bool = true) throws -> DiskImageAttachPlan {
        try ArchivePlanner.validatePaths([image])
        guard ["dmg", "sparseimage", "sparsebundle", "iso", "cdr"].contains(image.pathExtension.lowercased()) else {
            throw ArchivePlanningError.unsupportedFormat(image.pathExtension)
        }
        var arguments = ["attach", "-plist", "-nobrowse", "-noautoopen"]
        if readOnly { arguments.append("-readonly") }
        arguments.append(image.standardizedFileURL.path)
        return DiskImageAttachPlan(image: image, command: ArchiveCommand(executablePath: "/usr/bin/hdiutil",
            arguments: arguments, workingDirectory: image.deletingLastPathComponent()))
    }
    public static func result(_ process: ArchiveProcessResult, propertyList: Data) -> DiskImageAttachResult {
        if process.wasCancelled { return .cancelled }
        guard process.exitCode == 0, process.terminationSignal == nil else {
            return .failed(code: process.terminationSignal ?? process.exitCode, diagnostic: process.standardError)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: propertyList, options: [], format: nil),
              let root = plist as? [String: Any], let entities = root["system-entities"] as? [[String: Any]] else { return .invalidResponse }
        var mounts: [URL] = []
        for entity in entities {
            guard let path = entity["mount-point"] as? String else { continue }
            guard path.hasPrefix("/"), !path.contains("\0") else { return .invalidResponse }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if !mounts.contains(url) { mounts.append(url) }
        }
        return mounts.isEmpty ? .invalidResponse : .mounted(mounts)
    }
}
