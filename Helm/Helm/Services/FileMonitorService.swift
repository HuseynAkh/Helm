import Foundation
import CoreServices

enum FileChangeEvent {
    case created(URL)
    case modified(URL)
    case deleted(URL)
    case renamed(URL)
    case directoryChanged(URL)
}

actor FileMonitorService {

    private var stream: FSEventStreamRef?
    private var continuation: AsyncStream<FileChangeEvent>.Continuation?
    private let dispatchQueue = DispatchQueue(label: "com.helm.filemonitor", qos: .utility)

    func monitor(directory: URL) -> AsyncStream<FileChangeEvent> {
        stopMonitoring()

        return AsyncStream { continuation in
            self.continuation = continuation

            let pathString = directory.path as CFString
            let paths = [pathString] as CFArray

            var context = FSEventStreamContext()
            context.info = Unmanaged.passRetained(ContinuationBox(continuation)).toOpaque()
            context.release = { info in
                guard let info else { return }
                Unmanaged<ContinuationBox>.fromOpaque(info).release()
            }

            let flags: FSEventStreamCreateFlags = UInt32(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagNoDefer
            )

            guard let stream = FSEventStreamCreate(
                nil,
                fsEventCallback,
                &context,
                paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.3, // 300ms latency
                flags
            ) else {
                continuation.finish()
                return
            }

            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, dispatchQueue)
            FSEventStreamStart(stream)

            let streamIdentifier = UInt(bitPattern: stream)
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.handleTermination(for: streamIdentifier)
                }
            }
        }
    }

    func stopMonitoring() {
        let activeStream = stream
        stream = nil

        continuation?.finish()
        continuation = nil

        if let activeStream {
            releaseStream(activeStream)
        }
    }

    private func handleTermination(for streamIdentifier: UInt) {
        guard let activeStream = stream,
              UInt(bitPattern: activeStream) == streamIdentifier else {
            return
        }

        releaseStream(activeStream)
        stream = nil
        continuation = nil
    }

    private func releaseStream(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

private final class ContinuationBox: @unchecked Sendable {
    let continuation: AsyncStream<FileChangeEvent>.Continuation

    init(_ continuation: AsyncStream<FileChangeEvent>.Continuation) {
        self.continuation = continuation
    }
}

private func fsEventCallback(
    streamRef: ConstFSEventStreamRef,
    clientInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientInfo = clientInfo else { return }
    let box = Unmanaged<ContinuationBox>.fromOpaque(clientInfo).takeUnretainedValue()

    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()

    for i in 0..<numEvents {
        guard let cfPath = CFArrayGetValueAtIndex(paths, i) else { continue }
        let path = Unmanaged<CFString>.fromOpaque(cfPath).takeUnretainedValue() as String
        let url = URL(fileURLWithPath: path)
        let flags = eventFlags[i]

        let event: FileChangeEvent
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
            event = .created(url)
        } else if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
            event = .deleted(url)
        } else if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
            event = .renamed(url)
        } else if flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 {
            event = .modified(url)
        } else {
            event = .directoryChanged(url)
        }

        box.continuation.yield(event)
    }
}
