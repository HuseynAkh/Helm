// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-050 window policy without I/O. Owner closure retires callbacks and pending confirmations.
/// Same-item reuse is owner-scoped; all callbacks bind to a fresh selection incarnation (B-009).
public struct InspectorSessionRegistry: Equatable, Sendable {
    public private(set) var sessions: [InspectorSession]
    private var confirmations: [UUID: InfoPresentationRequest]
    private var closedOwners: Set<UUID>
    public init() { sessions = []; confirmations = [:]; closedOwners = [] }

    public mutating func reduce(event: InspectorSessionEvent) -> [InspectorSessionEffect] {
        switch event {
        case .present(let request):
            guard !closedOwners.contains(request.ownerID), !request.entries.isEmpty else { return [] }
            if request.mode == .perItem && request.entries.count > 10 {
                let token = UUID(); confirmations[token] = request
                return [.confirmMany(token, request)]
            }
            return present(request)
        case .confirmMany(let token, let approved):
            guard let request = confirmations.removeValue(forKey: token), approved,
                  !closedOwners.contains(request.ownerID) else { return [] }
            return present(request)
        case .ownerClosed(let owner):
            closedOwners.insert(owner)
            confirmations = confirmations.filter { $0.value.ownerID != owner }
            let ids = sessions.filter { $0.ownerID == owner }.map(\.id)
            return ids.flatMap { close($0) }
        case .close(let id): return close(id)
        case .selectionChanged(let id, let entries):
            guard let index = sessions.firstIndex(where: { $0.id == id }),
                  sessions[index].mode == .followSelection else { return [] }
            let request = InfoPresentationRequest(ownerID: sessions[index].ownerID,
                                                  mode: .followSelection, entries: entries)
            if sessions[index].entries == request.entries {
                sessions[index].pendingSelection = nil; sessions[index].decisionID = nil
                return []
            }
            if sessions[index].edits.isDirty {
                let token = UUID()
                sessions[index].pendingSelection = request; sessions[index].decisionID = token
                return [.decideSelection(sessionID: id, decisionID: token)]
            }
            return replace(index, request)
        case .decideSelection(let id, let token, let decision):
            guard let index = sessions.firstIndex(where: { $0.id == id }),
                  sessions[index].decisionID == token,
                  let request = sessions[index].pendingSelection else { return [] }
            sessions[index].pendingSelection = nil; sessions[index].decisionID = nil
            return decision == .discardEdits ? replace(index, request) : []
        case .edit(let id, let attribute):
            guard let index = sessions.firstIndex(where: { $0.id == id }),
                  sessions[index].enrichedIDs.count == sessions[index].entries.count else { return [] }
            sessions[index].edits.set(attribute)
            return []
        case .enriched(let request, let item):
            guard let index = sessions.firstIndex(where: { $0.id == request.sessionID }),
                  sessions[index].accepts(request), item.id == request.itemID,
                  !sessions[index].enrichedIDs.contains(item.id) else { return [] }
            sessions[index].enrichedIDs.insert(item.id)
            sessions[index].enrichedItems[item.id] = item
            sessions[index].edits = InspectorEditModel(items: sessions[index].entries.compactMap {
                sessions[index].enrichedItems[$0.id]
            })
            return []
        case .size(let request, let state):
            guard let index = sessions.firstIndex(where: { $0.id == request.sessionID }),
                  sessions[index].accepts(request), !sessions[index].finishedSizes.contains(request.itemID) else { return [] }
            sessions[index].sizes[request.itemID] = state
            switch state {
            case .final, .unavailable: sessions[index].finishedSizes.insert(request.itemID)
            case .partial, .calculating: break
            }
            return []
        }
    }

    private mutating func present(_ request: InfoPresentationRequest) -> [InspectorSessionEffect] {
        let requests: [InfoPresentationRequest] = request.mode == .perItem ? request.entries.map {
            InfoPresentationRequest(ownerID: request.ownerID, mode: .perItem, entries: [$0])
        } : [request]
        var effects: [InspectorSessionEffect] = []
        for next in requests {
            if let existing = sessions.first(where: {
                $0.ownerID == next.ownerID && $0.mode == next.mode &&
                (next.mode == .followSelection || $0.entries.map(\.id) == next.entries.map(\.id))
            }) {
                effects.append(.reuse(existing.id))
                if next.mode == .followSelection {
                    effects += reduce(event: .selectionChanged(sessionID: existing.id, entries: next.entries))
                }
            } else {
                let session = InspectorSession(request: next)
                sessions.append(session)
                effects.append(.open(session.id)); effects += session.reads.map(InspectorSessionEffect.read)
            }
        }
        return effects
    }
    private mutating func replace(_ index: Int, _ request: InfoPresentationRequest) -> [InspectorSessionEffect] {
        let old = sessions[index]
        sessions[index] = InspectorSession(id: old.id, request: request)
        return old.reads.map(InspectorSessionEffect.cancel) + sessions[index].reads.map(InspectorSessionEffect.read)
    }
    private mutating func close(_ id: UUID) -> [InspectorSessionEffect] {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return [] }
        let session = sessions.remove(at: index)
        return session.reads.map(InspectorSessionEffect.cancel) + [.close(id)]
    }
}
