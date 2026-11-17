#if os(macOS)
import Foundation
import HelmCore

/// Read contents on this Mac: summaries of what is inside files, for the AI panel's `read_contents` tool and for AI
/// search, made by `AgentContentExtractor` and never anywhere else. A summary holds words: a document's first lines
/// (text, RTF, Word, OpenDocument, PDF), and what Vision reads and sees in a picture, a video's frames and a scanned
/// PDF's first page. When a request asks, it also holds small JPEGs made on this Mac, with no metadata, of a picture,
/// of those frames and of that page. It sits beside the disk AI mode reads names from; the module that talks to a
/// model holds it only as `AgentContentReading` and can't open a file through it, only ask for summaries with the
/// person's permit.
///
/// Files are read off the main thread, four at a time, each with downloads off. Whatever isn't done when the time
/// runs out answers `not_responding`, pictures included; a read that is still going is left to finish on its own and
/// its answer dropped.
public final class AgentContentReader: AgentContentReading, @unchecked Sendable {
    private let queue: OperationQueue

    public init() {
        queue = OperationQueue()
        queue.name = "helm.read-contents"
        queue.maxConcurrentOperationCount = AgentContentLimits.filesAtOnce
        queue.qualityOfService = .utility
    }

    public func summaries(of requests: [AgentContentRequest], permit: AgentContentPermit, seconds: Double) async -> [AgentContentSummary] {
        guard !requests.isEmpty else { return [] }
        let deadline = DispatchTime.now() + max(0, seconds)
        let batch = AgentContentBatch(count: requests.count)
        let queue = self.queue
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                batch.wait(continuation)
                for (index, request) in requests.enumerated() {
                    queue.addOperation {
                        guard !batch.isFinished, DispatchTime.now() < deadline else { return }
                        batch.set(index, AgentContentExtractor.summary(of: request, deadline: deadline))
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { batch.finish() }
            }
        } onCancel: { batch.finish() }
    }
}

/// The summaries of one batch, as they come, and the one answer: when every file is done, or when time runs out.
private final class AgentContentBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [AgentContentSummary?]
    private var left: Int
    private var continuation: CheckedContinuation<[AgentContentSummary], Never>?
    private var answered = false

    init(count: Int) { found = Array(repeating: nil, count: count); left = count }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return answered
    }

    func wait(_ continuation: CheckedContinuation<[AgentContentSummary], Never>) {
        lock.lock()
        if answered {
            let answer = shaped()
            lock.unlock()
            continuation.resume(returning: answer)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func set(_ index: Int, _ summary: AgentContentSummary) {
        lock.lock()
        guard !answered, found.indices.contains(index), found[index] == nil else { lock.unlock(); return }
        found[index] = summary
        left -= 1
        let done = left == 0
        lock.unlock()
        if done { finish() }
    }

    func finish() {
        lock.lock()
        guard !answered else { lock.unlock(); return }
        answered = true
        let answer = shaped(), continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: answer)
    }

    /// Each summary, or `not_responding` for a file that wasn't done. Called with the lock held.
    private func shaped() -> [AgentContentSummary] {
        found.map { $0 ?? .notRead(.other, .not_responding) }
    }
}

/// What AI search has read inside pictures and videos during one search session, by path and modification date, so
/// a second search with the same words doesn't read them again. It is kept in memory only, and emptied when the
/// search's Read contents switch goes off, which it does when the search closes.
final class AgentContentMemo: @unchecked Sendable {
    private struct Key: Hashable { let path: String; let modified: Date }
    private let lock = NSLock()
    private var kept: [Key: AgentContentSummary] = [:]
    /// The most summaries kept. Past it the memo starts again.
    static let most = 2_000

    func summary(path: String, modified: Date) -> AgentContentSummary? {
        lock.lock(); defer { lock.unlock() }
        return kept[Key(path: path, modified: modified)]
    }

    func keep(_ summary: AgentContentSummary, path: String, modified: Date) {
        // A file that ran out of time is read again next time.
        guard summary.status != .not_responding else { return }
        lock.lock(); defer { lock.unlock() }
        if kept.count >= Self.most { kept.removeAll() }
        kept[Key(path: path, modified: modified)] = summary
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        kept.removeAll()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return kept.count
    }
}
#endif
