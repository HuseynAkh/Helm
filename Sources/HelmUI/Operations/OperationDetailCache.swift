// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-061 immutable outcomes format on demand, retaining only the current page (B-010).
final class OperationDetailCache: @unchecked Sendable {
    private let lock = NSLock()
    private var index: Int?
    private var lines: [String] = []
    private var formatted = 0
    init() {}
    var count: Int { lock.lock(); defer { lock.unlock() }; return formatted }
    func page(_ page: Int, create: () -> [String]) -> [String] {
        lock.lock(); defer { lock.unlock() }
        if index == page { return lines }
        lines = create(); index = page; formatted += lines.count
        return lines
    }
}
