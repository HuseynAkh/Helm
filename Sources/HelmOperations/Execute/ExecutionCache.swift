// DRAFT: pending review, 2026-11-05
import Foundation
import HelmCore
import HelmFileSystem

/// Per-execution name snapshots bound F-052 work; exclusive mutation still arbitrates races (B-039).
actor ExecutionCache {
    private let fileSystem: any FileSystem
    private var sensitivities: [String: Bool] = [:]
    private var occupied: [String: Set<String>] = [:]
    private let manifests: [String: [SourceEntry]]

    init(fileSystem: any FileSystem, context: PlanningContext) {
        self.fileSystem = fileSystem
        for (url, value) in context.caseSensitive { sensitivities[url.evidenceKey] = value }
        var index: [String: [SourceEntry]] = [:]
        // Index by ancestors once; avoids a whole-manifest scan for each leaf verification.
        for entry in context.sourceManifest {
            for path in SourcePathIndex.prefixes(entry.source.evidenceKey) { index[path, default: []].append(entry) }
        }
        manifests = index
    }
    func manifest(for source: URL) -> [SourceEntry] { manifests[source.evidenceKey, default: []] }
    func sensitivity(at parent: URL) async -> Bool {
        if let value = sensitivities[parent.evidenceKey] { return value }
        let value = (try? await fileSystem.isCaseSensitive(at: parent)) ?? false
        sensitivities[parent.evidenceKey] = value
        return value
    }
    func names(at parent: URL, refresh: Bool = false) async throws -> Set<String> {
        if !refresh, let names = occupied[parent.evidenceKey] { return names }
        let sensitive = await sensitivity(at: parent)
        let names = try await fileSystem.childNames(of: parent)
        let folded = Set(names.map { FileNameComparison.key($0, caseSensitive: sensitive) })
        occupied[parent.evidenceKey] = folded
        return folded
    }
    func completed(_ step: PlannedStep, destination: URL?) async {
        guard step.kind != .verifyCopy else { return }
        if (step.kind == .move || step.kind == .trash), let source = step.source {
            let parent = source.deletingLastPathComponent()
            if occupied[parent.evidenceKey] != nil {
                let sensitive = await sensitivity(at: parent)
                occupied[parent.evidenceKey]?.remove(FileNameComparison.key(source.lastPathComponent, caseSensitive: sensitive))
            }
        }
        if let destination {
            let parent = destination.deletingLastPathComponent()
            if occupied[parent.evidenceKey] != nil {
                let sensitive = await sensitivity(at: parent)
                occupied[parent.evidenceKey]?.insert(FileNameComparison.key(destination.lastPathComponent, caseSensitive: sensitive))
            }
        }
    }
}
