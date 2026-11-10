import Foundation

/// An item that a rename or a move took from one path to another. What Helm keeps by path, such as bookmarks and
/// stars, follows it, as Finder's sidebar follows a renamed folder.
public struct PathMove: Equatable, Sendable {
    public let from: URL
    public let to: URL
    public init(from: URL, to: URL) { self.from = from; self.to = to }
}

/// Renames and moves in the order they happened, read once so that many saved paths can follow them: a batch can
/// move thousands of items. Paths match as the disk sees them, whatever their Unicode form or `/private` prefix,
/// without asking the disk, which may be slow or far away.
public struct PathMoves: Sendable {
    private struct Step: Sendable {
        let source: [[UInt8]]
        let target: [String]
        let targetKey: [[UInt8]]
    }
    private let steps: [Step]

    public init(_ moves: [PathMove]) {
        steps = moves.compactMap { move in
            let source = Self.components(move.from.path)
            let target = Self.components(move.to.path)
            // The disk's root never moves.
            guard !source.isEmpty, !target.isEmpty else { return nil }
            return Step(source: source.map(PathSpelling.identity), target: target, targetKey: target.map(PathSpelling.identity))
        }
    }

    public var isEmpty: Bool { steps.isEmpty }

    /// Where the item at `path` is after the moves, taken in the order they happened: the item itself moved, or a
    /// folder it's inside did. Nil when none of them touched it. The new path is spelled as the move's destination
    /// is, which is how the disk and a fresh bookmark or star spell it.
    public func relocated(_ path: String) -> String? {
        guard !steps.isEmpty else { return nil }
        var parts = Self.components(path)
        var key = parts.map(PathSpelling.identity)
        var moved = false
        for step in steps where key.count >= step.source.count && key.prefix(step.source.count).elementsEqual(step.source) {
            parts = step.target + parts.dropFirst(step.source.count)
            key = step.targetKey + key.dropFirst(step.source.count)
            moved = true
        }
        return moved ? "/" + parts.joined(separator: "/") : nil
    }

    /// `records` once each has followed the moves, in their order. One that lands on a path another record keeps is
    /// dropped, so a folder moved over a bookmarked one leaves one bookmark, not two. Nil when nothing moved.
    public func relocate<Record>(_ records: [Record], path: (Record) -> String, rebuild: (Record, String) -> Record) -> [Record]? {
        guard !steps.isEmpty else { return nil }
        let destinations = records.map { relocated(path($0)) }
        guard destinations.contains(where: { $0 != nil }) else { return nil }
        var taken = Set(zip(records, destinations).compactMap { $1 == nil ? path($0) : nil })
        return zip(records, destinations).compactMap { record, destination in
            guard let destination else { return record }
            return taken.insert(destination).inserted ? rebuild(record, destination) : nil
        }
    }

    /// An absolute path's names, worked out from the text alone: "." and ".." are resolved, and `/private/tmp`,
    /// `/private/var` and `/private/etc` are the `/tmp`, `/var` and `/etc` they stand for, as in PathSpelling.
    private static func components(_ path: String) -> [String] {
        var parts: [String] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        #if canImport(Darwin)
        if parts.count > 1, parts[0] == "private", ["tmp", "var", "etc"].contains(parts[1]) { parts.removeFirst() }
        #endif
        return parts
    }
}
