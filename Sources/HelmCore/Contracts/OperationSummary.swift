import Foundation

/// Reducer-facing operation effects preserve rename selection and refresh scope (F-054, F-058).
public struct OperationSummary: Sendable, Equatable {
    public let id: OperationID
    public let affectedDirectories: Set<URL>
    public let renamedIDs: [ItemID: ItemID]
    public let createdIDs: [ItemID]
    public let failureCount: Int
    public init(id: OperationID, affectedDirectories: Set<URL>, renamedIDs: [ItemID: ItemID], createdIDs: [ItemID], failureCount: Int) {
        self.id = id; self.affectedDirectories = affectedDirectories; self.renamedIDs = renamedIDs
        self.createdIDs = createdIDs; self.failureCount = failureCount
    }
}
