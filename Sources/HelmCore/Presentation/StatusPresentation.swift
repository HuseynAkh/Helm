// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Injectable, locale-aware size labels for F-064 without capacity I/O (B-058).
public protocol StatusByteFormatting: Sendable {
    func string(from bytes: Int64) -> String
}

/// Uses the platform's localized file-size convention, preserving F-064.
public struct LocalizedStatusByteFormatter: StatusByteFormatting {
    public init() {}
    public func string(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Explicit progress/error text prevents failed listings appearing empty (B-017).
public enum StatusActivity: Sendable, Equatable {
    case idle, searching, gathering, denied
    /// Something the window started that has no row in the operations panel, such as compressing.
    case working(String)
}

/// Legacy wording is the F-064 default; fractional selection wording is opt-in.
public enum StatusSelectionWording: Sendable { case legacy, fraction }

/// Snapshot-derived status inputs preserve F-064; cached capacity fixes B-058.
public struct StatusPresentation: Sendable {
    public let itemCount: Int
    public let selectedCount: Int
    public let selectedBytes: Int64?
    public let freeBytes: Int64?
    public let activity: StatusActivity
    /// Search results are counted as results, so the bar doesn't read as the folder's own contents.
    public let isSearch: Bool
    public init(itemCount: Int, selectedCount: Int = 0, selectedBytes: Int64? = nil,
                freeBytes: Int64? = nil, activity: StatusActivity = .idle, isSearch: Bool = false) {
        self.isSearch = isSearch
        self.itemCount = max(0, itemCount)
        self.selectedCount = min(max(0, selectedCount), max(0, itemCount))
        self.selectedBytes = selectedBytes
        self.freeBytes = freeBytes
        self.activity = activity
    }
}

extension StatusText {
    /// Legacy labels and spacing: Helm/Helm/Views/AppKit/StatusBar.swift:43-58 (F-064).
    /// Progress labels and selected size are new; no filesystem access occurs here.
    public static func format(_ value: StatusPresentation,
                              bytes: any StatusByteFormatting = LocalizedStatusByteFormatter(),
                              selectionWording: StatusSelectionWording = .legacy) -> String {
        var parts: [String] = []
        switch value.activity {
        case .idle: break
        case .searching: parts.append("Searching…")
        case .gathering: parts.append("Gathering items…")
        case .working(let text): parts.append(text)
        case .denied: return "Permission denied"
        }
        if selectionWording == .fraction && value.selectedCount > 0 {
            parts.append("\(value.selectedCount) of \(value.itemCount) selected")
        } else {
            let noun = value.isSearch ? "result" : "item"
            parts.append(value.itemCount == 1 ? "1 \(noun)" : "\(value.itemCount) \(noun)s")
            if value.selectedCount > 0 { parts.append("\(value.selectedCount) selected") }
        }
        if value.selectedCount > 0, let size = value.selectedBytes, size >= 0 {
            parts.append(bytes.string(from: size))
        }
        if let capacity = value.freeBytes, capacity >= 0 {
            parts.append("\(bytes.string(from: capacity)) free")
        }
        return parts.joined(separator: "  •  ")
    }
}
