// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

// Component prefixes avoid both quadratic selection scans and lexical sibling-prefix mistakes.
struct SourcePathIndex {
    private let work: PlannerWork?
    private var counts: [String: Int] = [:]
    private(set) var comparisons: Int = 0
    private(set) var overlaps: Bool = false
    init(paths: [String], work: PlannerWork? = nil) {
        self.work = work
        var selected: Set<String> = []
        for path in paths {
            comparisons += 1
            work?.selectionComparisons += 1
            if !selected.insert(path).inserted { overlaps = true }
            for prefix in Self.prefixes(path) {
                work?.selectionComparisons += 1
                counts[prefix, default: 0] += 1
            }
        }
        for path in paths {
            for prefix in Self.prefixes(path).dropLast() {
                comparisons += 1
                work?.selectionComparisons += 1
                if selected.contains(prefix) { overlaps = true }
            }
        }
    }
    func containsSelection(atOrBelow target: String, excluding source: String? = nil) -> Bool {
        work?.targetQueries += 1
        let excluded = source.map { $0 == target || $0.hasPrefix(target + "/") ? 1 : 0 } ?? 0
        return counts[target, default: 0] > excluded
    }
    static func prefixes(_ path: String) -> [String] {
        var prefix = ""
        return path.split(separator: "/").map { component in
            prefix += "/" + component
            return prefix
        }
    }
}
