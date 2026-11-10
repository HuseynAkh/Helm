// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Stable UI-test identities follow F-035 path identity, independent of locale, sort and selection.
/// Renames change identity, matching ItemID; IDs contain paths and must not be logged as telemetry.
public enum AccessibilityIdentifier {
    public enum Region: String, CaseIterable, Sendable {
        case content, sidebar, toolbar, tabs, location, suggestions, status, inspector, operations
    }
    public static func region(_ region: Region, scope: String = "main") -> String {
        "helm.a11y.v1." + component(scope) + "." + region.rawValue
    }
    public static func item(_ item: ItemID, in region: Region = .content, scope: String = "main") -> String {
        self.region(region, scope: scope) + ".item." + component(item.rawValue)
    }
    public static func control(_ name: String, in region: Region, scope: String = "main") -> String {
        self.region(region, scope: scope) + ".control." + component(name)
    }
    // Hex UTF-8 is reversible and delimiter-safe, with no randomized hash or lossy normalization.
    private static func component(_ value: String) -> String {
        value.utf8.map { byte in
            let value: String = String(byte, radix: 16)
            return value.count == 1 ? "0" + value : value
        }.joined()
    }
}
