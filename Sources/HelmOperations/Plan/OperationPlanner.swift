// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Pure F-052–F-057 planning reuses K2 naming and refuses virtual background targets (B-031).
public enum OperationPlanner {
    public static func transfer(sources: [URL], to location: Location, moving: Bool, context: PlanningContext) -> OperationPlan {
        guard let target = location.mutationTarget else {
            return OperationPlan(command: .recovery, steps: [], issues: [.virtualLocationTarget], context: context)
        }
        return plan(moving ? .move(sources: sources, destinationDirectory: target) : .copy(sources: sources, destinationDirectory: target), context: context)
    }
    public static func creation(name: ValidFileName, in location: Location, folder: Bool, template: URL? = nil,
                                context: PlanningContext) -> OperationPlan {
        guard let parent = location.mutationTarget else {
            return OperationPlan(command: .recovery, steps: [], issues: [.virtualLocationTarget], context: context)
        }
        return plan(folder ? .createFolder(parent: parent, name: name) : .createFile(parent: parent, name: name, template: template), context: context)
    }
    public static func resolve(_ plan: OperationPlan, with policy: ConflictPolicy) -> OperationPlan {
        let c = plan.context
        return self.plan(plan.command, context: PlanningContext(sourceManifest: c.sourceManifest, availableBytes: c.availableBytes,
            caseSensitive: c.caseSensitive, existingNames: c.existingNames, volumeIDs: c.volumeIDs, defaultPolicy: policy))
    }
    public static func plan(_ command: Command, context: PlanningContext) -> OperationPlan {
        plan(command, context: context, work: PlannerWork())
    }
    static func plan(_ command: Command, context: PlanningContext, work: PlannerWork) -> OperationPlan {
        var builder = PlanAssembly(command: command, context: context, work: work)
        builder.build()
        return OperationPlan(command: command, steps: builder.issues.contains(where: \.isBlocking) ? [] : builder.steps,
                             issues: builder.issues, context: context)
    }
}

private struct PlanAssembly {
    let command: Command
    let context: PlanningContext
    let work: PlannerWork
    var steps: [PlannedStep] = []
    var issues: [PlanningIssue] = []
    var reserved: [String: Set<String>] = [:]
    var requiredBytes: [String: Int64] = [:]
    var manifestBytes: [String: Int64] = [:]
    var pathCache: [URL: String] = [:]
    mutating func build() {
        for item in context.sourceManifest {
            work.manifestVisits += 1
            guard item.kind != .directory && item.kind != .package else { continue }
            for prefix in SourcePathIndex.prefixes(item.source.standardizedFileURL.path) {
                work.manifestAggregations += 1
                let sum = manifestBytes[prefix, default: 0].addingReportingOverflow(max(0, item.size))
                manifestBytes[prefix] = sum.overflow ? Int64.max : sum.partialValue
            }
        }
        switch command {
        case .copy(let sources, let parent): transfers(sources, parent: parent, moving: false)
        case .move(let sources, let parent): transfers(sources, parent: parent, moving: true)
        case .duplicate(let sources):
            guard validateSources(sources) else { return }
            for source in sources { transfer(source, parent: source.deletingLastPathComponent(), moving: false) }
        case .trash(let sources):
            guard validateSources(sources) else { return }
            steps = sources.map { PlannedStep(kind: .trash, source: $0) }
        case .rename(let pair): renames([pair])
        case .batchRename(let pairs): renames(pairs)
        case .createFolder(let parent, let name): create(parent: parent, name: name, template: nil, folder: true)
        case .createFile(let parent, let name, let template): create(parent: parent, name: name, template: template, folder: false)
        case .recovery: issues.append(.stopped)
        }
    }
    mutating func path(_ url: URL) -> String {
        if let cached = pathCache[url] { return cached }
        let value = FileNameComparison.key(url.standardizedFileURL.path, caseSensitive: context.sensitive(at: url.deletingLastPathComponent()))
        pathCache[url] = value
        return value
    }
    mutating func valid(_ url: URL) -> Bool {
        guard url.isFileURL, url.path != "/", url.host == nil || url.host == "" || url.host == "localhost" else { issues.append(.invalidURL(url)); return false }
        return true
    }
    mutating func validateSources(_ sources: [URL]) -> Bool {
        for source in sources { _ = valid(source) }
        let index = SourcePathIndex(paths: sources.map { path($0) }, work: work)
        if index.overlaps, let source = sources.first { issues.append(.overlappingSelection(source)) }
        return issues.isEmpty
    }
    mutating func transfers(_ sources: [URL], parent: URL, moving: Bool) {
        guard validateSources(sources) else { return }
        let sensitive = context.sensitive(at: parent)
        let sourceKeys = sources.map { FileNameComparison.key($0.standardizedFileURL.path, caseSensitive: sensitive) }
        let index = SourcePathIndex(paths: sourceKeys, work: work)
        for (source, sourceKey) in zip(sources, sourceKeys) {
            let target = parent.appendingPathComponent(source.lastPathComponent)
            let targetKey = FileNameComparison.key(target.standardizedFileURL.path, caseSensitive: sensitive)
            if index.containsSelection(atOrBelow: targetKey, excluding: sourceKey) {
                issues.append(.overlappingSelection(target)); return
            }
        }
        for source in sources { transfer(source, parent: parent, moving: moving) }
    }
    mutating func loadNames(_ parent: URL) -> Bool {
        guard parent.isFileURL else { issues.append(.invalidURL(parent)); return false }
        let key = parent.standardizedFileURL.path
        if reserved[key] != nil { return true }
        guard let value = context.names(at: parent) else { issues.append(.missingSnapshot(parent)); return false }
        let sensitive = context.sensitive(at: parent)
        reserved[key] = Set(value.map { FileNameComparison.key($0, caseSensitive: sensitive) })
        return true
    }
    mutating func unique(_ name: String, parent: URL) -> URL? {
        guard loadNames(parent) else { return nil }
        let key = parent.standardizedFileURL.path
        let sensitive = context.sensitive(at: parent)
        guard let result = try? UniqueNamer.name(for: name, exists: {
            reserved[key, default: []].contains(FileNameComparison.key($0, caseSensitive: sensitive))
        }) else { issues.append(.invalidName); return nil }
        reserved[key, default: []].insert(FileNameComparison.key(result.value, caseSensitive: sensitive))
        return parent.appendingPathComponent(result.value)
    }
    mutating func checkSpace(source: URL, parent: URL) {
        work.byteLookups += 1
        let bytes = manifestBytes[source.standardizedFileURL.path, default: 0]
        let sum = requiredBytes[parent.path, default: 0].addingReportingOverflow(bytes)
        let total = sum.overflow ? Int64.max : sum.partialValue
        requiredBytes[parent.path] = total
        if let capacity = context.availableBytes.first(where: { $0.key.path == parent.path })?.value, total > capacity {
            issues.append(.insufficientSpace(parent))
        }
    }
    mutating func transfer(_ source: URL, parent: URL, moving: Bool) {
        if path(parent) == path(source) || path(parent).hasPrefix(path(source) + "/") {
            issues.append(.destinationInsideSource(parent)); return
        }
        if moving && path(source.deletingLastPathComponent()) == path(parent) {
            issues.append(.sameParentMove(source)); return
        }
        guard loadNames(parent) else { return }
        let target = parent.appendingPathComponent(source.lastPathComponent)
        let sensitive = context.sensitive(at: parent)
        let collision = reserved[parent.standardizedFileURL.path, default: []].contains(FileNameComparison.key(source.lastPathComponent, caseSensitive: sensitive))
        let policy = context.defaultPolicy.resolution(for: source)
        if collision && policy == .skip { return }
        if collision && policy == .stop { issues.append(.stopped); return }
        if !moving || context.volumeIDs[source] == nil || context.volumeIDs[source] != context.volumeIDs[parent] || (collision && policy == .replace) {
            checkSpace(source: source, parent: parent)
        }
        if collision && policy == .replace {
            let sourceKey = FileNameComparison.key(source.standardizedFileURL.path, caseSensitive: sensitive)
            let targetKey = FileNameComparison.key(target.standardizedFileURL.path, caseSensitive: sensitive)
            guard sourceKey != targetKey else { issues.append(.sourceEqualsDestination(source)); return }
            guard !sourceKey.hasPrefix(targetKey + "/") else {
                issues.append(.overlappingSelection(target)); return
            }
            replacement(source, target: target, moving: moving); return
        }
        guard let destination = unique(source.lastPathComponent, parent: parent) else { return }
        if moving {
            let sourceVolume = context.volumeIDs[source]
            let targetVolume = context.volumeIDs[parent]
            if let sourceVolume, sourceVolume == targetVolume {
                steps.append(PlannedStep(kind: .move, source: source, destination: destination, retryKeepBoth: true))
            } else {
                // No retirement until the injected copier verifies the completed copy.
                steps.append(PlannedStep(kind: .copy, source: source, destination: destination))
                steps.append(PlannedStep(kind: .verifyCopy, source: source, destination: destination))
                steps.append(PlannedStep(kind: .trash, source: source, verificationDestination: destination))
            }
        } else { steps.append(PlannedStep(kind: .copy, source: source, destination: destination, retryKeepBoth: true)) }
    }
    mutating func replacement(_ source: URL, target: URL, moving: Bool) {
        let parent = target.deletingLastPathComponent()
        guard let stage = unique(".helm-stage-" + target.lastPathComponent, parent: parent),
              let backup = unique(".helm-backup-" + target.lastPathComponent, parent: parent) else { return }
        // Fable/Opus: each boundary is recoverable, not an atomic multi-item transaction.
        steps.append(PlannedStep(kind: .copy, source: source, destination: stage))
        steps.append(PlannedStep(kind: .verifyCopy, source: source, destination: stage))
        steps.append(PlannedStep(kind: .move, source: target, destination: backup))
        steps.append(PlannedStep(kind: .move, source: stage, destination: target))
        steps.append(PlannedStep(kind: .trash, source: backup))
        if moving { steps.append(PlannedStep(kind: .trash, source: source, verificationDestination: target)) }
    }
    mutating func create(parent: URL, name: ValidFileName, template: URL?, folder: Bool) {
        if let template {
            guard valid(template) else { return }
            if path(parent) == path(template) || path(parent).hasPrefix(path(template) + "/") { issues.append(.destinationInsideSource(parent)); return }
        }
        guard let destination = unique(name.value, parent: parent) else { return }
        steps.append(PlannedStep(kind: folder ? .createDirectory : (template == nil ? .createFile : .copy),
                                 source: template, destination: destination, retryKeepBoth: true, collisionName: name.value))
    }
    mutating func renames(_ pairs: [RenamePair]) {
        guard validateSources(pairs.map(\.source)) else { return }
        for parent in Set(pairs.map { $0.source.deletingLastPathComponent() }).sorted(by: { $0.path < $1.path }) {
            guard loadNames(parent) else { return }
            let group = pairs.filter { $0.source.deletingLastPathComponent() == parent }
            let result = BatchRenamePlanner.plan(renames: group, existingNames: context.existingNames, caseSensitive: context.sensitive(at: parent))
            if !result.issues.isEmpty { issues.append(.collision(parent)); return }
            steps += result.steps.map { PlannedStep(kind: .move, source: $0.source, destination: $0.source.deletingLastPathComponent().appendingPathComponent($0.newName.value)) }
        }
    }
}
