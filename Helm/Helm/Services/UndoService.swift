import Foundation
import AppKit

/// Wraps UndoManager to provide undo/redo for file operations
@MainActor
class UndoService {

    private let fileOperationService = FileOperationService()

    /// Registers an undo action for a completed file operation
    func registerUndo(for result: FileOperationResult, undoManager: UndoManager?) {
        guard let undoManager else { return }

        switch result.kind {
        case .copy:
            // Undo copy = delete the copies
            undoManager.registerUndo(withTarget: self) { [weak self] target in
                Task { @MainActor in
                    try? await self?.fileOperationService.deleteItems(result.destinationURLs)
                }
            }
            undoManager.setActionName("Copy")

        case .move:
            // Undo move = move back to original locations
            undoManager.registerUndo(withTarget: self) { [weak self] target in
                Task { @MainActor in
                    for (dest, source) in zip(result.destinationURLs, result.sourceURLs) {
                        let parentDir = source.deletingLastPathComponent()
                        _ = try? await self?.fileOperationService.moveItems([dest], to: parentDir)
                    }
                }
            }
            undoManager.setActionName("Move")

        case .trash:
            // Undo trash = move from trash back to original location
            undoManager.registerUndo(withTarget: self) { [weak self] target in
                Task { @MainActor in
                    for (trashURL, originalURL) in zip(result.destinationURLs, result.sourceURLs) {
                        let parentDir = originalURL.deletingLastPathComponent()
                        _ = try? await self?.fileOperationService.moveItems([trashURL], to: parentDir)
                    }
                }
            }
            undoManager.setActionName("Move to Trash")

        case .rename:
            // Undo rename = rename back
            guard let oldURL = result.sourceURLs.first,
                  let newURL = result.destinationURLs.first else { return }
            undoManager.registerUndo(withTarget: self) { [weak self] target in
                Task { @MainActor in
                    _ = try? await self?.fileOperationService.renameItem(
                        at: newURL,
                        to: oldURL.lastPathComponent
                    )
                }
            }
            undoManager.setActionName("Rename")

        case .createDirectory, .createFile:
            // Undo create = delete
            undoManager.registerUndo(withTarget: self) { [weak self] target in
                Task { @MainActor in
                    try? await self?.fileOperationService.deleteItems(result.destinationURLs)
                }
            }
            undoManager.setActionName(result.kind == .createDirectory ? "New Folder" : "New File")
        }
    }
}
