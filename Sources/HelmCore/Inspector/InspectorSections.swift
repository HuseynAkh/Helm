// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-050 Properties sections retain independent disclosure preferences (P-094).
public enum InspectorSection: String, CaseIterable, Sendable, Codable {
    case general, moreInfo, nameAndExtension, comments, openWith, preview, permissions
}

/// F-050 persistence payload only; the persistence adapter owns storage and scope.
/// Raw keys preserve future/unknown sections when an older client round-trips the value.
public struct InspectorSections: Equatable, Sendable, Codable {
    public private(set) var expandedByKey: [String: Bool]
    public init(expandedByKey: [String: Bool] = [:]) { self.expandedByKey = expandedByKey }
    public func isExpanded(_ section: InspectorSection) -> Bool {
        expandedByKey[section.rawValue] ?? (section == .general || section == .nameAndExtension)
    }
    public mutating func setExpanded(_ expanded: Bool, for section: InspectorSection) {
        expandedByKey[section.rawValue] = expanded
    }
}
