// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Spoken and visual metadata for content badges (F-035/F-067); never reads file contents.
public struct ContentBadge: Equatable, Sendable {
    public let symbol: String
    public let label: String
    public init(symbol: String, label: String) { self.symbol = symbol; self.label = label }
}

/// Rendering-only mappings preserve dimming and drop feedback (F-035/F-036/F-051/F-067).
public enum ContentLeafPresentation {
    public static func cloudBadge(_ availability: CloudAvailability) -> ContentBadge? {
        switch availability {
        case .local, .unknown: return nil
        case .evicted: return ContentBadge(symbol: "icloud.and.arrow.down", label: "Available in cloud")
        case .downloading: return ContentBadge(symbol: "arrow.down.circle", label: "Downloading")
        }
    }
    public static func dragBadge(_ feedback: DropFeedback) -> ContentBadge {
        switch feedback {
        case .copy: return ContentBadge(symbol: "plus.circle.fill", label: "Copy")
        case .move: return ContentBadge(symbol: "arrow.right.circle.fill", label: "Move")
        case .alias: return ContentBadge(symbol: "arrow.turn.up.right", label: "Create Alias")
        case .trash: return ContentBadge(symbol: "trash", label: "Move to Trash")
        case .forbidden: return ContentBadge(symbol: "nosign", label: "Drop Not Allowed")
        }
    }
    public static func opacity(isHidden: Bool, isCut: Bool) -> Double {
        (isHidden ? 0.5 : 1) * (isCut ? 0.5 : 1)
    }
    /// The overlay and the hosting grid share top-left content coordinates (F-035).
    /// Scrolling/viewport conversion belongs to the gesture owner, not this leaf.
    public static func rubberBand(_ rect: CGRect?, geometry: GridGeometry) -> CGRect? {
        guard let rect, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        let normalized: CGRect = rect.standardized
        guard normalized.maxX.isFinite, normalized.maxY.isFinite else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: geometry.availableWidth, height: geometry.contentHeight)
        let clipped: CGRect = normalized.intersection(bounds)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }
    public static func isHighlighted(_ target: DropHighlight, proposal: FileDropProposal?) -> Bool {
        target != .none && proposal?.highlight == target
    }
}
