import Foundation

/// Deterministic English size text for F-064/F-066, replacing platform-dependent ByteCountFormatter.
/// Decimal (1000) matches the old `.file` convention; binary uses 1024 and IEC suffixes.
/// Uses up to one fractional digit, omits trailing zero, and groups exact bytes with commas.
public enum ByteCountText {
    public enum Style: Sendable { case decimal, binary }
    public static func format(_ bytes: Int64, style: Style = .decimal) -> String {
        let base: Double = style == .decimal ? 1000 : 1024
        let units = style == .decimal ? ["bytes", "KB", "MB", "GB", "TB", "PB", "EB"]
            : ["bytes", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        var amount = Double(bytes.magnitude)
        var unit = 0
        while amount >= base && unit < units.count - 1 { amount /= base; unit += 1 }
        if unit == 0 { return "\(bytes) \(bytes == 1 ? "byte" : "bytes")" }
        amount = (amount * 10).rounded() / 10
        if amount >= base && unit < units.count - 1 { amount /= base; unit += 1 }
        let number = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), amount)
        let trimmed = number.hasSuffix(".0") ? String(number.dropLast(2)) : number
        return "\(bytes < 0 ? "-" : "")\(trimmed) \(units[unit])"
    }
    public static func formatExact(_ bytes: Int64) -> String {
        let digits = String(bytes.magnitude)
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return "\(bytes < 0 ? "-" : "")\(result) bytes"
    }
}
