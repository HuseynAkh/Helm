#if os(macOS)
import AppKit
import AVFoundation
import Darwin
import Foundation
import HelmCore
import HelmFileSystem
import PDFKit
import UniformTypeIdentifiers
import Vision

/// The one place Helm looks inside a file, for Read contents. Everything here runs on this Mac with Apple's own
/// frameworks: PDFKit for a PDF's text, Vision for the text in a picture and what it shows, AVFoundation for a video's
/// length and a few of its frames. Nothing is sent anywhere, and the privacy check lets only this file name those
/// frameworks. Only `AgentContentReader`, which holds the person's permit, calls it.
///
/// Every byte is read by Helm itself, from a file it opened without following a link and with downloads off: a file
/// kept in a cloud and not on this Mac is refused by macOS rather than fetched, and answers `not_downloaded`. A
/// video's bytes reach AVFoundation through a loader that reads them the same way, so AVFoundation never opens the
/// file itself. Speech in a video is not listened to: macOS asks the person before an app may recognize speech,
/// which a background read can't do.
enum AgentContentExtractor {
    /// What one file holds, read within `deadline`.
    static func summary(of request: AgentContentRequest, deadline: DispatchTime) -> AgentContentSummary {
        let ext = (request.name as NSString).pathExtension
        let kind = AgentContentLimits.kind(typeIdentifier: request.typeIdentifier, extension: ext, kind: .regular)
        guard kind != .other else { return .notRead(.other, .unsupported) }
        if request.isDataless { return .notRead(kind, .not_downloaded) }
        let opened = DatalessGuard.withDownloadsOff { AgentContentFile.open(request) }
        let file: AgentContentFile
        switch opened {
        case .success(let found): file = found
        case .failure(let status): return .notRead(kind, status)
        }
        defer { file.close() }
        switch kind {
        case .text:
            guard file.length <= AgentContentLimits.textFileBytes else { return .notRead(kind, .too_large) }
            return text(file, isRich: AgentContentLimits.richTextExtensions.contains(ext.lowercased()))
        case .pdf:
            guard file.length <= AgentContentLimits.textFileBytes else { return .notRead(kind, .too_large) }
            return pdf(file)
        case .image:
            guard file.length <= AgentContentLimits.imageFileBytes else { return .notRead(kind, .too_large) }
            guard let data = file.bytes(upTo: file.length) else { return .notRead(kind, .unreadable) }
            let seen = look(at: VNImageRequestHandler(data: data, options: [:]))
            guard let seen else { return .notRead(kind, .unreadable) }
            return AgentContentSummary(kind: .image, status: .read, labels: seen.labels, foundText: seen.text)
        case .video:
            return video(file, ext: ext, deadline: deadline)
        case .other:
            return .notRead(.other, .unsupported)
        }
    }

    // MARK: Text and PDFs

    /// The first lines of a text file, read from its first bytes only. Rich text is read whole, as RTF can't be read in
    /// part, and never as HTML, which could ask for pictures from the web.
    private static func text(_ file: AgentContentFile, isRich: Bool) -> AgentContentSummary {
        if isRich {
            guard let data = file.bytes(upTo: file.length),
                  let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                     documentAttributes: nil) else { return .notRead(.text, .unreadable) }
            return AgentContentSummary(kind: .text, status: .read, lines: lines(of: rich.string, characters: AgentContentLimits.textCharacters))
        }
        guard let data = file.bytes(upTo: textBytesRead) else { return .notRead(.text, .unreadable) }
        let words = decoded(data, whole: file.length <= textBytesRead)
        return AgentContentSummary(kind: .text, status: .read, lines: lines(of: words, characters: AgentContentLimits.textCharacters))
    }

    /// How much of a text file is read: enough for the characters kept, whatever the encoding.
    private static let textBytesRead: Int64 = 24 * 1024

    /// The words of a text file's first bytes: UTF-16 when it starts with that mark, else UTF-8, else Windows Latin.
    /// A character cut in two at the end of what was read is left out.
    static func decoded(_ data: Data, whole: Bool) -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let even = whole ? data : data.prefix(data.count - data.count % 2)
            return String(data: even, encoding: .utf16) ?? ""
        }
        for cut in 0...(whole ? 0 : 3) where cut < bytes.count || cut == 0 {
            if let text = String(bytes: bytes.dropLast(cut), encoding: .utf8) { return text }
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// A PDF's first lines, page by page, from at most `pdfPages` pages. A locked PDF isn't read.
    private static func pdf(_ file: AgentContentFile) -> AgentContentSummary {
        guard let data = file.bytes(upTo: file.length), let document = PDFDocument(data: data) else { return .notRead(.pdf, .unreadable) }
        guard !document.isLocked else { return .notRead(.pdf, .unreadable) }
        var collected: [String] = []
        var count = 0
        for index in 0..<min(document.pageCount, pdfPages) where count < AgentContentLimits.textCharacters {
            let pageLines = lines(of: document.page(at: index)?.string ?? "", characters: AgentContentLimits.textCharacters - count)
            count += pageLines.reduce(0) { $0 + $1.count }
            collected += pageLines
        }
        return AgentContentSummary(kind: .pdf, status: .read, lines: collected, pages: document.pageCount)
    }

    private static let pdfPages = 20

    /// The lines of `text`, each trimmed, empty ones left out, `characters` at most in all: the last is cut to fit.
    static func lines(of text: String, characters: Int) -> [String] {
        var kept: [String] = []
        var left = characters
        for raw in text.components(separatedBy: .newlines) where left > 0 {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let cut = String(line.prefix(left))
            kept.append(cut)
            left -= cut.count
        }
        return kept
    }

    // MARK: Pictures

    /// What a picture shows and the text in it, from Vision's on-device text recognition (accurate, with language
    /// correction) and image classification. Nil when Vision couldn't read it.
    private static func look(at handler: VNImageRequestHandler) -> (labels: [AgentContentLabel], text: [String])? {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        let classify = VNClassifyImageRequest()
        do { try handler.perform([text, classify]) } catch { return nil }
        // Top to bottom, then left to right, as the text is read.
        let observations = (text.results ?? []).sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }
        let found = lines(of: observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"),
                          characters: AgentContentLimits.foundTextCharacters)
        let labels: [AgentContentLabel] = (classify.results ?? [])
            .filter { Double($0.confidence) >= AgentContentLimits.labelConfidence }
            .map { AgentContentLabel(identifier: $0.identifier, confidence: Double($0.confidence)) }
            .sorted(by: comesFirst)
        return (Array(labels.prefix(AgentContentLimits.labels)), found)
    }

    // MARK: Videos

    /// A video's length, and what three to five frames taken evenly through it show and say. Its bytes come only
    /// through `AgentContentVideoBytes`.
    private static func video(_ file: AgentContentFile, ext: String, deadline: DispatchTime) -> AgentContentSummary {
        let contentType = UTType(filenameExtension: ext)?.identifier ?? UTType.movie.identifier
        let bytes = AgentContentVideoBytes(file: file, contentType: contentType)
        guard let address = URL(string: AgentContentVideoBytes.address) else { return .notRead(.video, .unreadable) }
        let asset = AVURLAsset(url: address)
        asset.resourceLoader.setDelegate(bytes, queue: bytes.queue)
        let answer = AgentContentVideoAnswer()
        let work = Task {
            do {
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { answer.finish(.notRead(.video, .unreadable)); return }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1280, height: 1280)
                let frames = AgentContentLimits.frames(forSeconds: duration)
                var best: [String: Double] = [:]
                var text: [String] = []
                var looked = 0
                for index in 0..<frames {
                    try Task.checkCancellation()
                    let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(frames), preferredTimescale: 600)
                    guard let image = try? await generator.image(at: time).image,
                          let seen = look(at: VNImageRequestHandler(cgImage: image, options: [:])) else { continue }
                    looked += 1
                    for label in seen.labels { best[label.identifier] = max(best[label.identifier] ?? 0, label.confidence) }
                    for line in seen.text where !text.contains(line) { text.append(line) }
                }
                guard looked > 0 else { answer.finish(.notRead(.video, .unreadable)); return }
                let labels: [AgentContentLabel] = best.map { AgentContentLabel(identifier: $0.key, confidence: $0.value) }
                    .sorted(by: comesFirst)
                let found = lines(of: text.joined(separator: "\n"), characters: AgentContentLimits.foundTextCharacters)
                answer.finish(AgentContentSummary(kind: .video, status: .read, labels: Array(labels.prefix(AgentContentLimits.labels)),
                                                  foundText: found, seconds: duration, frames: looked))
            } catch {
                answer.finish(.notRead(.video, Task.isCancelled ? .not_responding : .unreadable))
            }
        }
        let summary = answer.wait(until: deadline) ?? .notRead(.video, .not_responding)
        work.cancel()
        bytes.stop()
        return summary
    }
}

/// The more certain label first, and between two as certain the one first in the alphabet, so the order is the same
/// every time.
private func comesFirst(_ label: AgentContentLabel, _ other: AgentContentLabel) -> Bool {
    if label.confidence != other.confidence { return label.confidence > other.confidence }
    return label.identifier < other.identifier
}

/// A file opened for Read contents: a plain file, opened without following a link, still the item the folder rules
/// admitted, and on this Mac. Reads go straight to the descriptor, each with downloads off.
final class AgentContentFile: @unchecked Sendable {
    private let descriptor: Int32
    let length: Int64
    private let lock = NSLock()
    private var isOpen = true

    private init(descriptor: Int32, length: Int64) { self.descriptor = descriptor; self.length = length }

    /// Opens the request's file. Called with downloads off.
    static func open(_ request: AgentContentRequest) -> Result<AgentContentFile, AgentContentStatus> {
        var before = stat()
        guard lstat(request.path, &before) == 0 else { return .failure(.unreadable) }
        // Only a plain file: a link, a folder, a device or a pipe is never opened.
        guard before.st_mode & S_IFMT == S_IFREG else { return .failure(.unreadable) }
        if before.st_flags & UInt32(SF_DATALESS) != 0 { return .failure(.not_downloaded) }
        let descriptor = Darwin.open(request.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return .failure(errno == EDEADLK ? .not_downloaded : .unreadable) }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_mode & S_IFMT == S_IFREG, after.st_dev == before.st_dev,
              after.st_ino == before.st_ino, after.st_flags & UInt32(SF_DATALESS) == 0, isSame(after, request.identity) else {
            _ = Darwin.close(descriptor)
            return .failure(.unreadable)
        }
        return .success(AgentContentFile(descriptor: descriptor, length: Int64(after.st_size)))
    }

    /// The file is the one the folder rules admitted, when they gave its identity as a device and an inode.
    private static func isSame(_ status: stat, _ identity: FileObjectIdentity?) -> Bool {
        guard let identity, identity.scope.hasPrefix("native:") else { return true }
        return identity.scope == "native:\(status.st_dev)" && identity.object == "\(status.st_ino)"
    }

    /// The first `count` bytes. Nil when they couldn't be read, as when the file turned out not to be on this Mac.
    func bytes(upTo count: Int64) -> Data? { bytes(at: 0, count: count) }

    /// `count` bytes from `offset`, or fewer at the end of the file.
    func bytes(at offset: Int64, count: Int64) -> Data? {
        let wanted = Int(max(0, min(count, length - offset)))
        guard wanted > 0 else { return Data() }
        var data = Data(count: wanted)
        var done = 0
        let ok: Bool = DatalessGuard.withDownloadsOff {
            lock.lock()
            defer { lock.unlock() }
            guard isOpen else { return false }
            return data.withUnsafeMutableBytes { buffer -> Bool in
                guard let base = buffer.baseAddress else { return false }
                while done < wanted {
                    let got = pread(descriptor, base + done, wanted - done, off_t(offset) + off_t(done))
                    if got < 0, errno == EINTR { continue }
                    guard got > 0 else { return got == 0 }
                    done += got
                }
                return true
            }
        }
        return ok ? data.prefix(done) : nil
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return }
        isOpen = false
        _ = Darwin.close(descriptor)
    }
}

/// Hands a video's bytes to AVFoundation from Helm's own reads, so AVFoundation never opens the file and every byte
/// is read with downloads off. The address is a name for this loader alone, not a place on any network.
final class AgentContentVideoBytes: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let address = "helm-contents:video"
    let queue = DispatchQueue(label: "helm.read-contents.video", qos: .utility)
    private let file: AgentContentFile
    private let contentType: String
    private let lock = NSLock()
    private var stopped = false
    /// The most handed over in one answer.
    private static let chunk: Int64 = 1 << 20

    init(file: AgentContentFile, contentType: String) { self.file = file; self.contentType = contentType }

    /// No more bytes are handed over.
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else {
            loadingRequest.finishLoading(with: CocoaError(.fileReadUnknown))
            return true
        }
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = file.length
            information.isByteRangeAccessSupported = true
        }
        if let wanted = loadingRequest.dataRequest {
            var offset = wanted.currentOffset
            let end = wanted.requestsAllDataToEndOfResource ? file.length : min(file.length, wanted.requestedOffset + Int64(wanted.requestedLength))
            while offset < end {
                guard let data = file.bytes(at: offset, count: min(Self.chunk, end - offset)), !data.isEmpty else {
                    loadingRequest.finishLoading(with: CocoaError(.fileReadUnknown))
                    return true
                }
                wanted.respond(with: data)
                offset += Int64(data.count)
            }
        }
        loadingRequest.finishLoading()
        return true
    }
}

/// A video's summary, from the work or from the clock.
private final class AgentContentVideoAnswer: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var summary: AgentContentSummary?

    func finish(_ summary: AgentContentSummary) {
        lock.lock()
        let first = self.summary == nil
        if first { self.summary = summary }
        lock.unlock()
        if first { done.signal() }
    }

    func wait(until deadline: DispatchTime) -> AgentContentSummary? {
        guard done.wait(timeout: deadline) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return summary
    }
}
#endif
