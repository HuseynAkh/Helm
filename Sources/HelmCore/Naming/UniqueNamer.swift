import Foundation

/// Destination-volume comparison for F-054/F-055, including canonical Unicode and case (B-047).
public enum FileNameComparison {
    public static func key(_ name: String, caseSensitive: Bool) -> String {
        let normalized = name.decomposedStringWithCanonicalMapping
        return caseSensitive ? normalized : normalized.folding(options: .caseInsensitive,
            locale: Locale(identifier: "en_US_POSIX")).decomposedStringWithCanonicalMapping
    }
}

/// Preserves F-052/F-056/F-057 numeric suffixes and NSString's final-extension split.
/// Thus a.tar.gz becomes a.tar 2.gz (legacy B-116 behaviour, explicitly retained).
/// Callers include dangling symlinks in occupied names and retry execution-time EEXIST (B-039).
public enum UniqueNamer {
    public static func name(for raw: String, existingNames: Set<String>,
                            caseSensitive: Bool = false) throws -> ValidFileName {
        let occupied = Set(existingNames.map { FileNameComparison.key($0, caseSensitive: caseSensitive) })
        return try name(for: raw) { occupied.contains(FileNameComparison.key($0, caseSensitive: caseSensitive)) }
    }
    /// The closure checks occupancy using the destination's comparison rules.
    public static func name(for raw: String, exists: (String) -> Bool) throws -> ValidFileName {
        let original = try FileNameValidator.validate(raw).get()
        if !exists(original.value) { return original }
        let base = (original.value as NSString).deletingPathExtension
        let ext = (original.value as NSString).pathExtension
        var counter = 2
        while true {
            let suffix = " \(counter)" + (ext.isEmpty ? "" : ".\(ext)")
            var stem = base
            while stem.utf8.count + suffix.utf8.count > 255 && !stem.isEmpty { stem.removeLast() }
            let candidate = try FileNameValidator.validate(stem + suffix).get()
            if !exists(candidate.value) { return candidate }
            guard counter < Int.max else { throw FileNameError.tooLong }
            counter += 1
        }
    }
}
