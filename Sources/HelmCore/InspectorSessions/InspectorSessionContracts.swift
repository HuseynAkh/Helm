// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-050 presentation intent; summary and following selection extend legacy single-item Info.
public struct InfoPresentationRequest: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case perItem, summary, followSelection }
    public let ownerID: UUID
    public let mode: Mode
    public let entries: [FileEntry]
    public init(ownerID: UUID, mode: Mode, entries: [FileEntry]) {
        self.ownerID = ownerID; self.mode = mode
        var seen: Set<ItemID> = []
        self.entries = entries.filter { seen.insert($0.id).inserted }
    }
}

/// F-050 callback identity binds one item to one selection incarnation (B-009).
public struct InspectorReadRequest: Equatable, Sendable {
    public let sessionID: UUID
    public let generation: UUID
    public let itemID: ItemID
    public let url: URL
    public init(sessionID: UUID, generation: UUID, itemID: ItemID, url: URL) {
        self.sessionID = sessionID; self.generation = generation
        self.itemID = itemID; self.url = url
    }
}

/// F-050 dirty selection changes require an explicit discard or keep decision; neither writes.
public enum InspectorSelectionDecision: Equatable, Sendable { case discardEdits, keepSelection }

/// F-050 value events; callers retain exact tokens from effects across asynchronous reads.
public enum InspectorSessionEvent: Equatable, Sendable {
    case present(InfoPresentationRequest)
    case confirmMany(UUID, approved: Bool)
    case selectionChanged(sessionID: UUID, entries: [FileEntry])
    case decideSelection(sessionID: UUID, decisionID: UUID, InspectorSelectionDecision)
    case edit(sessionID: UUID, InspectorAttribute)
    case enriched(InspectorReadRequest, InspectorItem)
    case size(InspectorReadRequest, InspectorSizeState)
    case close(UUID)
    case ownerClosed(UUID)
}

/// F-050 host intents only: adapters own windows, PropertiesLoader reads and cancellation.
public enum InspectorSessionEffect: Equatable, Sendable {
    case open(UUID), reuse(UUID), close(UUID)
    case confirmMany(UUID, InfoPresentationRequest)
    case decideSelection(sessionID: UUID, decisionID: UUID)
    case read(InspectorReadRequest), cancel(InspectorReadRequest)
}

/// F-050 session snapshot retains edits and separates computed contents from metadata (B-066).
public struct InspectorSession: Equatable, Sendable {
    public let id: UUID
    public let ownerID: UUID
    public let mode: InfoPresentationRequest.Mode
    public internal(set) var entries: [FileEntry]
    public internal(set) var generation: UUID
    public internal(set) var edits: InspectorEditModel
    public internal(set) var sizes: [ItemID: InspectorSizeState]
    private let readURLs: [ItemID: URL]
    var enrichedItems: [ItemID: InspectorItem] = [:]
    var enrichedIDs: Set<ItemID> = []
    var finishedSizes: Set<ItemID> = []
    var pendingSelection: InfoPresentationRequest?
    var decisionID: UUID?

    public init(id: UUID = UUID(), request: InfoPresentationRequest) {
        self.id = id; ownerID = request.ownerID; mode = request.mode
        entries = request.entries; generation = UUID()
        readURLs = Dictionary(uniqueKeysWithValues: request.entries.map { ($0.id, $0.url) })
        edits = InspectorEditModel(items: []); sizes = [:]
    }
    public var sizeProjection: InspectorSizeProjection {
        InspectorSizeProjection(entries: entries, computed: sizes)
    }
    var reads: [InspectorReadRequest] {
        entries.map { InspectorReadRequest(sessionID: id, generation: generation, itemID: $0.id, url: $0.url) }
    }
    // Admission does not materialize the selection's read effects for each progress event.
    func accepts(_ request: InspectorReadRequest) -> Bool {
        request.sessionID == id && request.generation == generation && readURLs[request.itemID] == request.url
    }
}
