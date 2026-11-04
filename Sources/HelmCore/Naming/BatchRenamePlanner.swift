import Foundation

/// Pure F-055 preview, validation and swap planning (B-046/B-047).
/// Existing names are complete directory snapshots, including dangling symlinks.
public enum BatchRenamePlanner {
    public static func plan(items: [URL], rule: BatchRenameRule,
                            existingNames: [URL: Set<String>] = [:], caseSensitive: Bool = false,
                            date: Date = Date(), timeZone: TimeZone = .current) -> BatchRenamePlan {
        var previews: [RenamePreview] = []
        var pairs: [RenamePair] = []
        var issues: [BatchRenameIssue] = []
        for (index, source) in items.enumerated() {
            do {
                let raw = try rule.name(for: source.lastPathComponent, index: index, date: date, timeZone: timeZone)
                previews.append(RenamePreview(source: source, proposedName: raw))
                switch FileNameValidator.validate(raw) {
                case .success(let name): pairs.append(RenamePair(source: source, newName: name))
                case .failure(let error): issues.append(.invalidName(source, error))
                }
            } catch { issues.append(.counterOverflow(source)) }
        }
        return assemble(pairs: pairs, previews: previews, issues: issues,
                        existingNames: existingNames, caseSensitive: caseSensitive)
    }

    /// Explicit targets also support arbitrary permutations and case-only renames.
    public static func plan(renames: [RenamePair], existingNames: [URL: Set<String>] = [:],
                            caseSensitive: Bool = false) -> BatchRenamePlan {
        assemble(pairs: renames,
                 previews: renames.map { RenamePreview(source: $0.source, proposedName: $0.newName.value) },
                 issues: [], existingNames: existingNames, caseSensitive: caseSensitive)
    }

    private static func assemble(pairs: [RenamePair], previews: [RenamePreview],
                                 issues initialIssues: [BatchRenameIssue], existingNames: [URL: Set<String>],
                                 caseSensitive: Bool) -> BatchRenamePlan {
        var issues = initialIssues
        func key(_ name: String) -> String { FileNameComparison.key(name, caseSensitive: caseSensitive) }
        func directoryKey(_ url: URL) -> URL {
            URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        }
        func parent(_ url: URL) -> URL { directoryKey(url.deletingLastPathComponent()) }
        var sources: [URL: Set<String>] = [:]
        var targets: [URL: Set<String>] = [:]
        var occupied: [URL: Set<String>] = [:]
        for (directory, names) in existingNames {
            occupied[directoryKey(directory), default: []].formUnion(names.map(key))
        }
        for pair in pairs {
            let directory = parent(pair.source)
            if !sources[directory, default: []].insert(key(pair.source.lastPathComponent)).inserted {
                issues.append(.duplicateSource(pair.source))
            }
            occupied[directory, default: []].insert(key(pair.source.lastPathComponent))
        }
        for pair in pairs {
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
        let changed = pairs.filter { Array($0.source.lastPathComponent.utf8) != Array($0.newName.value.utf8) }
        guard issues.isEmpty else {
            return BatchRenamePlan(previews: previews, renames: changed, steps: [], issues: issues)
        }
        for (directory, names) in targets { occupied[directory, default: []].formUnion(names) }
        var firstPhase: [RenamePair] = []
        var secondPhase: [RenamePair] = []
        for (index, pair) in changed.enumerated() {
            let directory = parent(pair.source)
            // Deterministic temporary names reserve against all sources and targets.
            do {
                let temporary = try UniqueNamer.name(for: ".helm-rename-\(index + 1)") {
                    occupied[directory, default: []].contains(key($0))
                }
                occupied[directory, default: []].insert(key(temporary.value))
                firstPhase.append(RenamePair(source: pair.source, newName: temporary))
                secondPhase.append(RenamePair(source: directory.appendingPathComponent(temporary.value), newName: pair.newName))
            } catch { issues.append(.invalidName(pair.source, .tooLong)) }
        }
        return BatchRenamePlan(previews: previews, renames: changed,
                               steps: issues.isEmpty ? firstPhase + secondPhase : [], issues: issues)
    }
}
