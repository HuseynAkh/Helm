import Foundation
import HelmCore

/// A disk that exists only in memory, for tests: folders, files, links and packages by path, with the marks a real
/// disk can carry (hidden, not downloaded, not loaded, refused by macOS) and the things a real place can do (answer
/// slowly, be a server or a cloud folder). It answers the four questions of `AgentDisk` and has no way to be
/// changed through them. Every path it is asked about is kept, so a test can show that a place was never touched.
/// All reads and writes hold the lock, and the lock is never held across a wait.
public final class MemoryAgentDisk: AgentDisk, @unchecked Sendable {
    private enum Shape: Equatable { case folder, file, package, shortcut(to: String) }

    private struct Node {
        var shape: Shape
        var identity: FileObjectIdentity
        var size: Int64 = 0
        var modified: Date = .distantPast
        var typeIdentifier: String?
        var isHidden = false, isDataless = false, isDenied = false
    }

    private let lock = NSLock()
    private let home: String
    private var nodes: [String: Node] = [:]
    private var serial = 0
    private var delays: [(prefix: [String], seconds: Double)] = []
    private var probes: [(prefix: [String], probe: StorageProbe)] = []
    private var paths: [String] = []

    /// A disk that holds the home folder and the folders above it, and nothing else.
    public init(home: String = "/home/helm") {
        self.home = Self.path(Self.parts(home))
        locked { put(.folder, at: Self.parts(home)) }
    }

    // MARK: Building the disk

    /// Adds a folder, and any folder above it that isn't there yet. So do the other `add` methods.
    public func addFolder(_ path: String) {
        locked { put(.folder, at: Self.parts(path)) }
    }

    public func addFile(_ path: String, size: Int64 = 0, modified: Date = .distantPast, typeIdentifier: String? = nil) {
        locked {
            let key = put(.file, at: Self.parts(path))
            nodes[key]?.size = size
            nodes[key]?.modified = modified
            nodes[key]?.typeIdentifier = typeIdentifier
        }
    }

    /// Adds a link that points at `target`: a whole path, or one that starts from the link's own folder. The target
    /// needn't exist.
    public func addLink(_ path: String, to target: String) {
        locked { put(.shortcut(to: target), at: Self.parts(path)) }
    }

    /// Adds a folder that macOS shows as one item, such as an app.
    public func addPackage(_ path: String) {
        locked { put(.package, at: Self.parts(path)) }
    }

    /// Removes an item and everything inside it.
    public func remove(_ path: String) {
        locked {
            let parts = Self.parts(path)
            for key in nodes.keys where Self.isAt(Self.parts(key), orInside: parts) { nodes[key] = nil }
        }
    }

    /// Puts a different object at the same path, as when a folder is deleted and another is made with its name.
    public func replaceIdentity(at path: String) {
        locked {
            let parts = Self.parts(path)
            guard nodes[Self.path(parts)] != nil else { return }
            nodes[Self.path(parts)]?.identity = nextIdentity(for: parts)
        }
    }

    /// Sets the mark macOS hides an item by. A name that starts with a dot needs no mark to be hidden.
    public func setHidden(_ path: String) {
        locked { nodes[Self.path(Self.parts(path))]?.isHidden = true }
    }

    /// Marks a file as kept in a cloud and not downloaded.
    public func markCloudOnly(_ path: String) {
        locked { nodes[Self.path(Self.parts(path))]?.isDataless = true }
    }

    /// Marks a folder as one whose names aren't loaded from its cloud. Listing it answers `notLoaded`.
    public func markNotLoaded(_ path: String) {
        locked { nodes[Self.path(Self.parts(path))]?.isDataless = true }
    }

    /// Marks a folder as one macOS won't let Helm list. Listing it answers `denied`.
    public func markDenied(_ path: String) {
        locked { nodes[Self.path(Self.parts(path))]?.isDenied = true }
    }

    /// Makes every question about a path at or under `prefix` take this long. A question that would take longer
    /// than its limit waits out the limit and then gets no answer, as a place that stopped responding gives none.
    public func setDelay(_ seconds: Double, under prefix: String) {
        locked {
            let parts = Self.parts(prefix)
            delays.removeAll { $0.prefix == parts }
            delays.append((parts, seconds))
        }
    }

    /// Sets the raw facts of every folder at or under `prefix`, from which its place is worked out. The longest
    /// prefix wins. A folder under no prefix has no facts, and is placed by its path alone.
    public func setProbe(_ probe: StorageProbe, under prefix: String) {
        locked {
            let parts = Self.parts(prefix)
            probes.removeAll { $0.prefix == parts }
            probes.append((parts, probe))
        }
    }

    /// Every path a question was asked about, in order.
    public var asked: [String] { locked { paths } }

    // MARK: AgentDisk

    public func canonicalPath(_ path: String) async -> String? {
        guard await answers(path, within: AgentLimits.diskSeconds) else { return nil }
        return locked { resolved(Self.parts(path)).map(Self.path) }
    }

    public func item(at path: String) async -> AgentDiskItem? {
        guard await answers(path, within: AgentLimits.diskSeconds) else { return nil }
        return locked {
            let parts = Self.parts(path)
            // Links in the folders above are followed, as a real disk follows them. The item itself never is.
            guard let above = resolved(Array(parts.dropLast())) else { return nil }
            let place = parts.isEmpty ? [] : above + [parts[parts.count - 1]]
            guard let node = nodes[Self.path(place)] else { return nil }
            return item(for: node, path: Self.path(parts), name: parts.last ?? "/")
        }
    }

    public func list(_ folder: String, limit: Int, idleSeconds: Double) async -> AgentDiskListing {
        guard await answers(folder, within: idleSeconds) else { return AgentDiskListing(items: [], state: .slow) }
        return locked {
            let parts = Self.parts(folder)
            guard let place = resolved(parts), let node = nodes[Self.path(place)], node.shape == .folder || node.shape == .package else {
                return AgentDiskListing(items: [], state: .gone)
            }
            if node.isDenied { return AgentDiskListing(items: [], state: .denied) }
            if node.isDataless { return AgentDiskListing(items: [], state: .notLoaded) }
            let own = facts(for: parts)
            let names = nodes.keys.map(Self.parts)
                .filter { $0.count == place.count + 1 && Self.isAt($0, orInside: place) }
                .compactMap(\.last).sorted(by: Self.comesFirst)
            let items = names.prefix(max(0, limit)).compactMap { name -> AgentDiskItem? in
                guard let child = nodes[Self.path(place + [name])] else { return nil }
                let path = Self.path(parts + [name])
                var differing: StorageFacts?
                // Only a child that can be in another place than its parent has its own facts looked at.
                if child.shape == .folder, StorageClassifier.mayDiffer(child: path, home: home, mirrors: [:]) {
                    let childFacts = facts(for: parts + [name])
                    if childFacts.placeKey != own.placeKey { differing = childFacts }
                }
                return item(for: child, path: path, name: name, place: differing)
            }
            return AgentDiskListing(items: Array(items), more: max(0, names.count - items.count))
        }
    }

    public func storage(of folder: String) async -> StorageFacts {
        let answered = await answers(folder, within: AgentLimits.diskSeconds)
        return locked {
            var probe = probe(for: Self.parts(folder))
            if !answered { probe.timedOut = true }
            return StorageClassifier.classify(path: Self.path(Self.parts(folder)), home: home, probe: probe)
        }
    }

    // MARK: Nodes

    /// Puts an item at a path, making the folders above it. An item of the same shape that is already there is
    /// kept as the object it is. Returns the item's key.
    @discardableResult private func put(_ shape: Shape, at parts: [String]) -> String {
        for count in 0..<parts.count {
            let above = Array(parts.prefix(count))
            if nodes[Self.path(above)] == nil { nodes[Self.path(above)] = Node(shape: .folder, identity: nextIdentity(for: above)) }
        }
        let key = Self.path(parts)
        if nodes[key]?.shape != shape { nodes[key] = Node(shape: shape, identity: nextIdentity(for: parts)) }
        return key
    }

    /// A new object on the disk the path is on. Each disk in the Volumes folder is a device of its own.
    private func nextIdentity(for parts: [String]) -> FileObjectIdentity {
        serial += 1
        let device = parts.count >= 2 && parts[0] == "Volumes" ? Self.path(Array(parts.prefix(2))) : "/"
        return FileObjectIdentity(scope: "memory:" + device, object: String(serial))
    }

    /// The path with every link in it followed. Nil when a part is missing or the links go round in a circle.
    private func resolved(_ parts: [String]) -> [String]? {
        var done: [String] = [], rest = parts, hops = 0
        while !rest.isEmpty {
            let name = rest.removeFirst()
            guard let node = nodes[Self.path(done + [name])] else { return nil }
            guard case .shortcut(let target) = node.shape else {
                done.append(name)
                continue
            }
            hops += 1
            guard hops <= Self.maximumHops else { return nil }
            rest = Self.parts(target.hasPrefix("/") ? target : Self.path(done) + "/" + target) + rest
            done = []
        }
        return done
    }

    private func item(for node: Node, path: String, name: String, place: StorageFacts? = nil) -> AgentDiskItem {
        let kind: FileEntryKind
        switch node.shape {
        case .folder: kind = .directory
        case .file: kind = .regular
        case .package: kind = .package
        case .shortcut(let target):
            let above = Array(Self.parts(path).dropLast())
            let end = resolved(Self.parts(target.hasPrefix("/") ? target : Self.path(above) + "/" + target))
            switch end.flatMap({ nodes[Self.path($0)]?.shape }) {
            case .folder?, .package?: kind = .symlinkToDirectory
            case .file?: kind = .symlinkToFile
            default: kind = .danglingSymlink
            }
        }
        return AgentDiskItem(path: path, name: name, kind: kind, identity: node.identity, size: node.size,
                             modified: node.modified, created: node.modified, typeIdentifier: node.typeIdentifier,
                             isHidden: node.isHidden, isDataless: node.isDataless, place: place)
    }

    private func facts(for parts: [String]) -> StorageFacts {
        StorageClassifier.classify(path: Self.path(parts), home: home, probe: probe(for: parts))
    }

    private func probe(for parts: [String]) -> StorageProbe {
        probes.filter { Self.isAt(parts, orInside: $0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.probe ?? StorageProbe()
    }

    // MARK: Waiting

    /// Notes the question, waits as long as the path's place takes to answer, and says whether it answered within
    /// `limit` seconds.
    private func answers(_ path: String, within limit: Double) async -> Bool {
        let delay = locked { () -> Double in
            paths.append(path)
            let parts = Self.parts(path)
            return delays.filter { Self.isAt(parts, orInside: $0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.seconds ?? 0
        }
        let wait = min(delay, limit)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        return delay <= limit
    }

    // MARK: Paths, by part

    private static let maximumHops = 32

    /// A path's parts, with "." left out and ".." taking the part before it away.
    private static func parts(_ path: String) -> [String] {
        var parts: [String] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(String(part)) }
        }
        return parts
    }

    private static func path(_ parts: [String]) -> String { "/" + parts.joined(separator: "/") }

    private static func isAt(_ parts: [String], orInside prefix: [String]) -> Bool {
        parts.count >= prefix.count && Array(parts.prefix(prefix.count)) == prefix
    }

    /// Names in the order a listing gives them: without regard to case, a run of digits by its value, and otherwise
    /// by code point, so the order is the same on every Mac whatever its language.
    private static func comesFirst(_ name: String, _ other: String) -> Bool {
        let left = Array(name.lowercased().unicodeScalars), right = Array(other.lowercased().unicodeScalars)
        var here = 0, there = 0
        while here < left.count, there < right.count {
            if isDigit(left[here]), isDigit(right[there]) {
                let number = digits(of: left, from: &here), otherNumber = digits(of: right, from: &there)
                if number.count != otherNumber.count { return number.count < otherNumber.count }
                if number != otherNumber { return number.lexicographicallyPrecedes(otherNumber) }
            } else {
                if left[here] != right[there] { return left[here].value < right[there].value }
                here += 1
                there += 1
            }
        }
        let rest = left.count - here, otherRest = right.count - there
        return rest == otherRest ? name < other : rest < otherRest
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

    /// The run of digits that starts at `index`, without the zeros it starts with. `index` ends up past the run.
    private static func digits(of scalars: [Unicode.Scalar], from index: inout Int) -> [UInt32] {
        var run: [UInt32] = []
        while index < scalars.count, isDigit(scalars[index]) {
            if !(run.isEmpty && scalars[index] == "0") { run.append(scalars[index].value) }
            index += 1
        }
        return run
    }

    @discardableResult private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
