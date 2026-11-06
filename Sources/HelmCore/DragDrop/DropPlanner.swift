// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Deterministic F-067 preflight with P-118 defaults and B-040 same-parent protection.
public enum DropPlanner {
    public static func proposal(sources: [DraggedItem], destination: DropDestination,
                                modifiers: DropModifiers = [],
                                allowedOperations: Set<FileDropOperation> = [.copy, .move, .moveToTrash]) -> FileDropProposal {
        proposal(validation: DropSourceValidation(sources: sources), destination: destination,
                 modifiers: modifiers, allowedOperations: allowedOperations)
    }

    static func proposal(validation: DropSourceValidation, destination: DropDestination,
                         modifiers: DropModifiers, allowedOperations: Set<FileDropOperation>) -> FileDropProposal {
        let sources = validation.sources
        func reject(_ reason: DropRejection) -> FileDropProposal {
            FileDropProposal(sources: sources, destination: destination, result: .failure(reason))
        }
        if let rejection = validation.rejection { return reject(rejection) }
        guard !destination.isSearchResults, destination.location != .recent else { return reject(.virtualDestination) }
        guard destination.isWritable else { return reject(.readOnlyDestination) }
        let paths = validation.paths
        if validation.overlaps { return reject(.overlappingSources) }
        let operation: FileDropOperation
        switch destination.location {
        case .recent: return reject(.virtualDestination)
        case .trash:
            guard !sources.contains(where: { $0.isInTrash }) else { return reject(.sameParentNoOp) }
            operation = .moveToTrash
        case .directory(let url):
            guard url.isFileURL else { return reject(.invalidFileURL) }
            guard destination.isDirectory else { return reject(.notDirectory) }
            guard !destination.isPackage || destination.allowsPackageContents else { return reject(.packageContentsDisallowed) }
            let target = url.standardizedFileURL.pathComponents
            for path in paths {
                if target == path { return reject(.intoItself) }
                if target.starts(with: path) { return reject(.intoDescendant) }
            }
            if modifiers.contains(.control) || modifiers.contains([.option, .command]) { operation = .alias }
            else if modifiers.contains(.option) { operation = .copy }
            else if modifiers.contains(.command) { operation = .move }
            else {
                let sameVolume = destination.volumeID.map { volume in
                    !volume.isEmpty && sources.allSatisfy { $0.volumeID == volume }
                } ?? false
                operation = sameVolume ? .move : .copy
            }
            // Explicit copying/aliasing beside the original is intentional. Moves are no-ops.
            if (operation == .move || modifiers.isEmpty) && sources.contains(where: {
                $0.url.standardizedFileURL.deletingLastPathComponent().pathComponents == target
            }) { return reject(.sameParentNoOp) }
        }
        guard allowedOperations.contains(operation) else { return reject(.unsupportedOperation) }
        return FileDropProposal(sources: sources, destination: destination, result: .success(operation))
    }
    // Internal comparison seam makes the preflight work bound testable without a clock.
    static func hasOverlappingPaths(_ paths: [[String]],
                                    isPrefix: ([String], [String]) -> Bool = { $0.starts(with: $1) }) -> Bool {
        // Component ordering puts every descendant directly after its ancestor's
        // range starts. Inspecting adjacent paths also catches duplicate sources.
        let ordered: [[String]] = paths.sorted { $0.lexicographicallyPrecedes($1) }
        for (ancestor, descendant) in zip(ordered, ordered.dropFirst()) {
            if isPrefix(descendant, ancestor) { return true }
        }
        return false
    }

}
