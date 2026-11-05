// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Explicit locale, calendar/time zone and clock for F-064 speech, without disk I/O (B-058).
/// Numbers and dates are localized; surrounding English phrases match Helm's current UI.
public struct AccessibilityFormatting: Sendable {
    public let locale: Locale
    public let calendar: Calendar
    public let clock: any HelmClock

    public init(locale: Locale, calendar: Calendar, clock: any HelmClock) {
        self.locale = locale
        self.calendar = calendar
        self.clock = clock
    }

    public func count(_ value: Int) -> String {
        let formatter = numberFormatter(fractionDigits: 0)
        return formatter.string(from: NSNumber(value: max(0, value))) ?? String(max(0, value))
    }

    /// Decimal file sizes preserve F-064 units; unknown negative metadata is omitted.
    public func bytes(_ value: Int64) -> String? {
        guard value >= 0 else { return nil }
        var amount: Double = Double(value)
        let units: [String] = [value == 1 ? "byte" : "bytes", "KB", "MB", "GB", "TB", "PB", "EB"]
        var unit: Int = 0
        while amount >= 1000 && unit < units.count - 1 { amount /= 1000; unit += 1 }
        amount = (amount * 10).rounded() / 10
        if amount >= 1000 && unit < units.count - 1 { amount /= 1000; unit += 1 }
        let formatter = numberFormatter(fractionDigits: unit == 0 ? 0 : 1)
        guard let number = formatter.string(from: NSNumber(value: amount)) else { return nil }
        return "\(number) \(units[unit])"
    }

    public func modifiedDate(_ date: Date, relative: Bool) -> String? {
        guard date != .distantPast, date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        if relative {
            let now: Date = clock.now()
            if now.timeIntervalSinceReferenceDate.isFinite {
                if calendar.isDate(date, inSameDayAs: now) { return "today" }
                if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                   calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
                if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                   calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
            }
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func numberFormatter(fractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        return formatter
    }
}
