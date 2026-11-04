// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Inspected archive member for P-389; F-007 delegation grows no implicit extraction permission.
/// Link and special-file entries are rejected conservatively, including links whose targets look safe.
public struct ArchiveMember: Equatable, Sendable {
    public enum Kind: String, Sendable { case file, directory, symbolicLink, hardLink, special }
    public let path: String
    public let kind: Kind
    public let expandedBytes: UInt64
    public let compressedBytes: UInt64
    public init(path: String, kind: Kind = .file, expandedBytes: UInt64, compressedBytes: UInt64) {
        self.path = path; self.kind = kind; self.expandedBytes = expandedBytes; self.compressedBytes = compressedBytes
    }
}

/// Explicit extraction budgets for P-389/F-007; runner must also enforce them while streaming output.
public struct ArchiveSafetyLimits: Equatable, Sendable {
    public let maximumMembers: Int
    public let maximumExpandedBytes: UInt64
    public let maximumRatio: Double
    public init(maximumMembers: Int = 100_000, maximumExpandedBytes: UInt64 = 10_000_000_000, maximumRatio: Double = 1000) {
        self.maximumMembers = maximumMembers; self.maximumExpandedBytes = maximumExpandedBytes; self.maximumRatio = maximumRatio
    }
}

/// Fail-closed listing preflight for P-389 (F-007); not a substitute for confined runtime extraction.
public enum ArchiveSafety {
    public static func validate(_ members: [ArchiveMember], limits: ArchiveSafetyLimits = ArchiveSafetyLimits(),
                                caseSensitive: Bool = false) throws {
        guard limits.maximumMembers >= 0, limits.maximumRatio.isFinite, limits.maximumRatio > 0 else {
            throw ArchivePlanningError.invalidLimits
        }
        guard members.count <= limits.maximumMembers else { throw ArchivePlanningError.expansionLimit }
        var total: UInt64 = 0
        var paths: [String: ArchiveMember.Kind] = [:]
        for member in members {
            let raw = member.path
            let components = raw.split(separator: "/", omittingEmptySubsequences: false)
            guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains("\\"), !raw.contains(":"),
                  !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !components.contains(".."), member.kind == .file || member.kind == .directory else {
                throw ArchivePlanningError.unsafeMember(raw)
            }
            let clean = components.filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
            if clean.isEmpty {
                guard member.kind == .directory, member.expandedBytes == 0 else {
                    throw ArchivePlanningError.unsafeMember(raw)
                }
                // Root markers carry no extraction metadata or payload authorization.
                continue
            }
            let key = FileNameComparison.key(clean, caseSensitive: caseSensitive)
            guard paths[key] == nil else { throw ArchivePlanningError.duplicateMember(raw) }
            paths[key] = member.kind
            let sum = total.addingReportingOverflow(member.expandedBytes)
            guard !sum.overflow, sum.partialValue <= limits.maximumExpandedBytes else { throw ArchivePlanningError.expansionLimit }
            total = sum.partialValue
            if member.expandedBytes > 0 && (member.compressedBytes == 0 || Double(member.expandedBytes) / Double(member.compressedBytes) > limits.maximumRatio) {
                throw ArchivePlanningError.ratioLimit
            }
        }
        for key in paths.keys {
            var pieces = key.split(separator: "/").map(String.init)
            while pieces.count > 1 {
                pieces.removeLast()
                if paths[pieces.joined(separator: "/")] == .file { throw ArchivePlanningError.unsafeMember(key) }
            }
        }
    }
}
