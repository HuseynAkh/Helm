// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Pure F-055 preview, validation and swap planning (B-046/B-047).
/// Existing names are complete directory snapshots, including dangling symlinks.
public enum BatchRenamePlanner {
    public static func plan(items: [URL], rule: BatchRenameRule,
                            existingNames: [URL: Set<String>] = [:], caseSensitive: Bool = false,
                            date: Date = Date(), timeZone: TimeZone = .current) -> BatchRenamePlan {
        // This hook cannot throw; all name validation errors become plan issues below.
        do { return try plan(items: items, rule: rule, existingNames: existingNames,
                             caseSensitive: caseSensitive, date: date, timeZone: timeZone, cancellationCheck: {}) }
        catch { return BatchRenamePlan(previews: [], renames: [], steps: [], issues: []) }
    }

    public static func plan(renames: [RenamePair], existingNames: [URL: Set<String>] = [:],
                            caseSensitive: Bool = false) -> BatchRenamePlan {
        do { return try plan(renames: renames, existingNames: existingNames,
                             caseSensitive: caseSensitive, cancellationCheck: {}) }
        catch { return BatchRenamePlan(previews: [], renames: [], steps: [], issues: []) }
    }

    /// Cooperative F-055 planning throws the supplied cancellation error, never a partial plan.
    public static func plan(items: [URL], rule: BatchRenameRule,
                            existingNames: [URL: Set<String>] = [:], caseSensitive: Bool = false,
                            date: Date = Date(), timeZone: TimeZone = .current,
                            cancellationCheck: () throws -> Void) throws -> BatchRenamePlan {
        try cancellationCheck()
        var previews: [RenamePreview] = []
        var pairs: [RenamePair] = []
        var issues: [BatchRenameIssue] = []
        for (index, source) in items.enumerated() {
            try cancellationCheck()
            do {
                let raw = try rule.name(for: source.lastPathComponent, index: index, date: date, timeZone: timeZone)
                previews.append(RenamePreview(source: source, proposedName: raw))
                switch FileNameValidator.validate(raw) {
                case .success(let name): pairs.append(RenamePair(source: source, newName: name))
                case .failure(let error): issues.append(.invalidName(source, error))
                }
            } catch { issues.append(.counterOverflow(source)) }
        }
        return try assemble(pairs: pairs, previews: previews, issues: issues,
                        existingNames: existingNames, caseSensitive: caseSensitive, cancellationCheck: cancellationCheck)
    }

    /// Explicit targets also support arbitrary permutations and case-only renames.
    public static func plan(renames: [RenamePair], existingNames: [URL: Set<String>] = [:],
                            caseSensitive: Bool = false,
                            cancellationCheck: () throws -> Void) throws -> BatchRenamePlan {
        try cancellationCheck()
        return try assemble(pairs: renames,
                 previews: try renames.map { try cancellationCheck(); return RenamePreview(source: $0.source, proposedName: $0.newName.value) },
                 issues: [], existingNames: existingNames, caseSensitive: caseSensitive, cancellationCheck: cancellationCheck)
    }

    private static func assemble(pairs: [RenamePair], previews: [RenamePreview],
                                 issues initialIssues: [BatchRenameIssue], existingNames: [URL: Set<String>],
                                 caseSensitive: Bool, cancellationCheck: () throws -> Void) throws -> BatchRenamePlan {
        try cancellationCheck()
        var issues = initialIssues
        // Component ordering bounds overlap validation to adjacent sorted sources.
        let ordered = try previews.map { preview in
            try cancellationCheck()
            return (url: preview.source, components: preview.source.standardizedFileURL.pathComponents.map {
                FileNameComparison.key($0, caseSensitive: caseSensitive)
            })
        }.sorted { $0.components.lexicographicallyPrecedes($1.components) }
        try cancellationCheck()
        for (ancestor, descendant) in zip(ordered, ordered.dropFirst()) {
            try cancellationCheck()
            if descendant.components.count > ancestor.components.count,
               descendant.components.starts(with: ancestor.components) {
                issues.append(.overlappingSources(ancestor.url, descendant.url))
            }
        }
        func key(_ name: String) -> String { FileNameComparison.key(name, caseSensitive: caseSensitive) }
        func directoryKey(_ url: URL) -> URL {
            URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        }
        func parent(_ url: URL) -> URL { directoryKey(url.deletingLastPathComponent()) }
        var sources: [URL: Set<String>] = [:]
        var targets: [URL: Set<String>] = [:]
        var occupied: [URL: Set<String>] = [:]
        for (directory, names) in existingNames {
            for name in names {
                try cancellationCheck()
                occupied[directoryKey(directory), default: []].insert(key(name))
            }
        }
        for pair in pairs {
            try cancellationCheck()
            let directory = parent(pair.source)
            if !sources[directory, default: []].insert(key(pair.source.lastPathComponent)).inserted {
                issues.append(.duplicateSource(pair.source))
            }
            occupied[directory, default: []].insert(key(pair.source.lastPathComponent))
        }
        for pair in pairs {
            try cancellationCheck()
            let directory = parent(pair.source)
            let target = key(pair.newName.value)
            let isDuplicate = !targets[directory, default: []].insert(target).inserted
            let isExternal = occupied[directory, default: []].contains(target)
                && !sources[directory, default: []].contains(target)
            if isDuplicate || isExternal {
                issues.append(.collision(directory.appendingPathComponent(pair.newName.value)))
            }
        }
        // Compare bytes to preserve normalization-only renames.
        let changed = try pairs.filter {
            try cancellationCheck()
            return Array($0.source.lastPathComponent.utf8) != Array($0.newName.value.utf8)
        }
        guard issues.isEmpty else {
            return BatchRenamePlan(previews: previews, renames: changed, steps: [], issues: issues)
        }
        for (directory, names) in targets {
            try cancellationCheck()
            occupied[directory, default: []].formUnion(names)
        }
        var firstPhase: [RenamePair] = []
        var secondPhase: [RenamePair] = []
        for (index, pair) in changed.enumerated() {
            try cancellationCheck()
            let directory = parent(pair.source)
            // Deterministic temporary names reserve against all sources and targets.
            var cancellationError: Error?
            do {
                let temporary = try UniqueNamer.name(for: ".helm-rename-\(index + 1)") {
                    do { try cancellationCheck() } catch { cancellationError = error; throw error }
                    return occupied[directory, default: []].contains(key($0))
                }
                occupied[directory, default: []].insert(key(temporary.value))
                firstPhase.append(RenamePair(source: pair.source, newName: temporary))
                secondPhase.append(RenamePair(source: directory.appendingPathComponent(temporary.value), newName: pair.newName))
            } catch {
                if let cancellationError { throw cancellationError }
                issues.append(.invalidName(pair.source, .tooLong))
            }
        }
        return BatchRenamePlan(previews: previews, renames: changed,
                               steps: issues.isEmpty ? firstPhase + secondPhase : [], issues: issues)
    }
}
