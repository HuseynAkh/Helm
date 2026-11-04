// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Deterministic F-067 preflight with P-118 defaults and B-040 same-parent protection.
public enum DropPlanner {
    public static func proposal(sources: [DraggedItem], destination: DropDestination,
                                modifiers: DropModifiers = [],
                                allowedOperations: Set<DropOperation> = [.copy, .move, .alias, .moveToTrash]) -> DropProposal {
        func reject(_ reason: DropRejection) -> DropProposal {
            DropProposal(sources: sources, destination: destination, result: .failure(reason))
        }
        guard !sources.isEmpty else { return reject(.emptySources) }
        guard sources.allSatisfy({ $0.url.isFileURL }) else { return reject(.invalidFileURL) }
        guard sources.allSatisfy({ $0.id == ItemID(url: $0.url) }) else { return reject(.identityMismatch) }
        guard !destination.isSearchResults, destination.location != .recent else { return reject(.virtualDestination) }
        guard destination.isWritable else { return reject(.readOnlyDestination) }
        let paths = sources.map { $0.url.standardizedFileURL.pathComponents }
        for index in paths.indices {
            for other in paths.indices where index != other {
                if paths[index].starts(with: paths[other]) { return reject(.overlappingSources) }
            }
        }
        let operation: DropOperation
        switch destination.location {
        case .recent: return reject(.virtualDestination)
        case .trash: operation = .moveToTrash
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
        return DropProposal(sources: sources, destination: destination, result: .success(operation))
    }
}
