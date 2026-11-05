import Foundation
import HelmCore

/// Direct-child mapping uses a canonical watched root, retaining the displayed symlink path (B-073).
/// Purely lexical: FSEvents reports paths under the exact string registered at stream creation, while
/// `standardizedFileURL` consults the disk, so a deleted child of `/private/...` would stop matching (FB1-3).
public enum MonitorPathFilter {
    public static func displayedPath(for eventPath: String, canonicalRoot: URL, displayedRoot: URL) -> String? {
        let event = lexicalComponents(of: eventPath)
        let root = lexicalComponents(of: canonicalRoot.path)
        guard event.count >= root.count, event.prefix(root.count).elementsEqual(root) else { return nil }
        let displayed = lexicalComponents(of: displayedRoot.path)
        if event.count == root.count { return "/" + displayed.joined(separator: "/") }
        guard event.count == root.count + 1 else { return nil }
        return "/" + (displayed + [event[root.count]]).joined(separator: "/")
    }
    private static func lexicalComponents(of path: String) -> [String] {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { _ = components.popLast(); continue }
            components.append(String(component))
        }
        return components
    }
}

#if os(macOS)
#if canImport(CoreServices)
import CoreServices

private final class FSEventContext {
    let canonicalRoot: URL
    let displayedRoot: URL
    let continuation: AsyncStream<MonitorEvent>.Continuation
    init(root: URL, continuation: AsyncStream<MonitorEvent>.Continuation) {
        canonicalRoot = root.resolvingSymlinksInPath(); displayedRoot = root; self.continuation = continuation
    }
}
/// Native path-aware monitor filters recursive callbacks to direct children (B-073).
public actor FSEventsMonitor: DirectoryMonitor {
    public nonisolated let events: AsyncStream<MonitorEvent>
    private let continuation: AsyncStream<MonitorEvent>.Continuation
    private let directory: URL
    private var stream: FSEventStreamRef?
    private let callbackQueue = DispatchQueue(label: "helm.fsevents", qos: .utility)
    public init(directory: URL) {
        self.directory = directory
        let pair = AsyncStream<MonitorEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
    }
    public func start() async throws {
        guard stream == nil else { return }
        let owner = FSEventContext(root: directory, continuation: continuation)
        // FSEvents copies the context and balances these retain/release callbacks.
        // The local owner covers creation; the stream owns callback lifetime after creation.
        var info = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(owner).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<FSEventContext>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<FSEventContext>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes |
                                            kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, pointer, count, paths, flags, _ in
            guard let pointer else { return }
            let owner = Unmanaged<FSEventContext>.fromOpaque(pointer).takeUnretainedValue()
            // UseCFTypes supplies a borrowed CFArray of CFString (same bridge as the old Helm monitor).
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
            var changed: Set<String> = []
            for index in 0..<count {
                let flag = flags[index]
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount) != 0 {
                    owner.continuation.yield(.volumeUnmounted); continue
                }
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                    owner.continuation.yield(.rootChanged); continue
                }
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                    owner.continuation.yield(.rescan); continue
                }
                guard let rawPath = CFArrayGetValueAtIndex(array, index) else { continue }
                let path = Unmanaged<CFString>.fromOpaque(rawPath).takeUnretainedValue() as String
                guard let displayed = MonitorPathFilter.displayedPath(for: path, canonicalRoot: owner.canonicalRoot,
                                                                      displayedRoot: owner.displayedRoot) else { continue }
                changed.insert(displayed)
            }
            if !changed.isEmpty { owner.continuation.yield(.changed(paths: changed)) }
        }
        guard let created = FSEventStreamCreate(nil, callback, &info, [owner.canonicalRoot.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            throw FileSystemError.unsupported
        }
        FSEventStreamSetDispatchQueue(created, callbackQueue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created)
            throw FileSystemError.unsupported
        }
        stream = created
    }
    public func stop() async {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil; continuation.finish()
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        continuation.finish()
    }
}
#endif

#endif
