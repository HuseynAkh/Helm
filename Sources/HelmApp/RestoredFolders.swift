import Foundation
import HelmCore
import HelmFileSystem

/// Which restored folders can reopen at launch, without letting a slow disk or an unanswered macOS question
/// hold launch up. Folders macOS asks about aren't read here at all: reading one can wait on that question.
/// Others get a moment each, all at once. Only a folder that's gone, or isn't a folder, is left out; anything
/// else reopens and its window says what's wrong, which is better than losing the tab.
enum RestoredFolders {
    static func availability(of urls: [URL], fileSystem: any FileSystem, home: URL,
                             deadline: TimeInterval = 2) async -> [URL: Bool] {
        var result: [URL: Bool] = [:]
        var pending: [URL] = []
        for url in urls where result[url] == nil && !pending.contains(url) {
            if let area = PrivacyAreas.area(containing: url, home: home), area.asksFirst { result[url] = true } else { pending.append(url) }
        }
        guard !pending.isEmpty else { return result }
        let answers = RestoreAnswers(expecting: pending.count)
        var checks: [Task<Void, Never>] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            answers.whenDone = { continuation.resume() }
            for url in pending {
                checks.append(Task.detached { answers.record(url, await isOpenable(url, fileSystem: fileSystem)) })
            }
            checks.append(Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, deadline) * 1_000_000_000))
                answers.finish()
            })
        }
        // Reads still going are left to finish on their own; their tabs reopen and show what happens.
        for check in checks { check.cancel() }
        let known = answers.values
        for url in pending { result[url] = known[url] ?? true }
        return result
    }

    static func isOpenable(_ url: URL, fileSystem: any FileSystem) async -> Bool {
        do {
            return try await fileSystem.entry(at: url).isDirectoryLike
        } catch {
            return FileSystemError.mapping(error) != .notFound
        }
    }
}

/// Answers as they arrive, and a single call when they're all in or time is up.
private final class RestoreAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [URL: Bool] = [:]
    private var remaining: Int
    private var done = false
    var whenDone: (() -> Void)?
    init(expecting count: Int) { remaining = count }

    func record(_ url: URL, _ openable: Bool) {
        lock.lock()
        answers[url] = openable
        remaining -= 1
        let finished = remaining <= 0
        lock.unlock()
        if finished { finish() }
    }
    func finish() {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let call = whenDone
        whenDone = nil
        lock.unlock()
        call?()
    }
    var values: [URL: Bool] {
        lock.lock(); defer { lock.unlock() }
        return answers
    }
}
