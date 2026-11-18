#if os(macOS)
import AppKit
import AVFoundation
import Darwin
import Foundation
import HelmCore
import HelmFileSystem
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// The one place Helm looks inside a file, for Read contents. Everything here runs on this Mac with Apple's own
/// frameworks: PDFKit for a PDF's text and its first page, Vision for the text in a picture and what it shows,
/// AVFoundation for a video's length and a few of its frames, ImageIO to decode a picture, and AppKit for rich text,
/// Word and OpenDocument files and for the small pictures a model looks at. Nothing here sends anything anywhere, and
/// the privacy check lets only this file name PDFKit, Vision and AVFoundation. Only `AgentContentReader`, which holds
/// the person's permit, calls it.
///
/// A picture is decoded once, by ImageIO. Its size is read from its header first, and a picture of more than
/// `mostPixels` is refused as too large before any of it is decoded. Otherwise one copy is made, `visionEdge` pixels at
/// most on its longer side and turned as its EXIF orientation says; Vision reads that copy, and a model's picture is
/// made from it. An animated picture gives its first frame.
///
/// When a request asks for pictures, it makes small JPEGs (`AgentContentImage`): a picture's first frame, each video
/// frame it looked at, and the first page of a PDF whose pages hold next to no text, as a scan's don't. Each is drawn
/// anew from decoded pixels, `AgentContentLimits.lookEdge` pixels at most on its longer side, and written with no
/// metadata at all; ImageIO then reads it back, and one in which it finds any metadata isn't sent. A scanned page is
/// read by Vision whether or not pictures are asked for, so its words are there for a model that can't take pictures.
/// Without a request for pictures, no picture is made.
///
/// Every byte is read by Helm itself, from a file it opened without following a link and with downloads off: a file
/// kept in a cloud and not on this Mac is refused by macOS rather than fetched, and answers `not_downloaded`. A
/// video's bytes reach AVFoundation through a loader that reads them the same way, so AVFoundation never opens the
/// file itself. A Word (.docx) or OpenDocument (.odt) file is a zip, and its directory is read first
/// (`AgentContentZip`): one that would unpack to too much, or looks built to, is refused as too large. Then it is read
/// from those bytes by readers that take its words alone: a linked picture, a template, a field that includes another
/// file and an XML entity are neither fetched nor opened. Rich text is always read as the type its extension names,
/// never as HTML or a web archive, which load what they link to. Word files from before 2007 (.doc) aren't read: their
/// reader is old and large. Speech in a video is not listened to: macOS asks the person before an app may recognize
/// speech, which a background read can't do.
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
            return text(file, ext: ext.lowercased())
        case .pdf:
            guard file.length <= AgentContentLimits.textFileBytes else { return .notRead(kind, .too_large) }
            return pdf(file, wantsImages: request.wantsImages, deadline: deadline)
        case .image:
            guard file.length <= AgentContentLimits.imageFileBytes else { return .notRead(kind, .too_large) }
            guard let data = file.bytes(upTo: file.length) else { return .notRead(kind, .unreadable) }
            let decoded: CGImage
            switch firstFrame(of: data) {
            case .success(let image): decoded = image
            case .failure(let status): return .notRead(kind, status)
            }
            guard let seen = look(at: VNImageRequestHandler(cgImage: decoded, options: [:])) else {
                return .notRead(kind, .unreadable)
            }
            // A picture costs time, so it is made only while there is time left.
            let wanted = request.wantsImages && DispatchTime.now() < deadline
            let images = wanted ? picture(of: decoded, source: .picture).map { [$0] } ?? [] : []
            return AgentContentSummary(kind: .image, status: .read, labels: seen.labels, foundText: seen.text, images: images)
        case .video:
            return video(file, ext: ext, wantsImages: request.wantsImages, deadline: deadline)
        case .other:
            return .notRead(.other, .unsupported)
        }
    }

    // MARK: Text and PDFs

    /// The first lines of a text file, read from its first bytes only. Rich text and word processor files are read
    /// whole, as they can't be read in part, from the bytes Helm read, by the reader their extension names, and never
    /// as HTML, which could ask for pictures from the web.
    private static func text(_ file: AgentContentFile, ext: String) -> AgentContentSummary {
        if let type = documentType(ext) {
            guard let data = file.bytes(upTo: file.length) else { return .notRead(.text, .unreadable) }
            // Word and OpenDocument files are zips, whose directory says what they unpack to. One that isn't a zip, or
            // whose directory can't be read, is unreadable; any other refusal is too large.
            if type != .rtf, let refusal = AgentContentZip.refusal(of: data) {
                return .notRead(.text, refusal == .unreadable ? .unreadable : .too_large)
            }
            guard let words = document(data, type: type) else { return .notRead(.text, .unreadable) }
            return AgentContentSummary(kind: .text, status: .read, lines: lines(of: words, characters: AgentContentLimits.textCharacters))
        }
        guard let data = file.bytes(upTo: textBytesRead) else { return .notRead(.text, .unreadable) }
        let words = decoded(data, whole: file.length <= textBytesRead)
        return AgentContentSummary(kind: .text, status: .read, lines: lines(of: words, characters: AgentContentLimits.textCharacters))
    }

    /// How much of a text file is read: enough for the characters kept, whatever the encoding.
    private static let textBytesRead: Int64 = 24 * 1024

    /// The reader for a rich text or word processor file: RTF, Word (.docx) or OpenDocument text
    /// (`AgentContentLimits.richTextExtensions` and `wordExtensions`). Each takes the words and their styles from the
    /// bytes alone; a file that isn't what its extension says is unreadable, never read as another type.
    private static func documentType(_ ext: String) -> NSAttributedString.DocumentType? {
        switch ext {
        case "rtf": return .rtf
        case "docx": return .officeOpenXML
        case "odt": return .openDocument
        default: return nil
        }
    }

    /// A rich text or word processor document's words, read as `type` and nothing else.
    private static func document(_ data: Data, type: NSAttributedString.DocumentType) -> String? {
        (try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil))?.string
    }

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

    /// A PDF's first lines, page by page, from at most `pdfPages` pages. A locked PDF isn't read. When those pages hold
    /// fewer than `AgentContentLimits.scannedPageCharacters`, as a scan's do, its first page is drawn and Vision reads
    /// the text in it and what it shows; that page is pictured for a model too when the request asks.
    private static func pdf(_ file: AgentContentFile, wantsImages: Bool, deadline: DispatchTime) -> AgentContentSummary {
        guard let data = file.bytes(upTo: file.length), let document = PDFDocument(data: data) else { return .notRead(.pdf, .unreadable) }
        guard !document.isLocked else { return .notRead(.pdf, .unreadable) }
        var collected: [String] = []
        var count = 0
        for index in 0..<min(document.pageCount, pdfPages) where count < AgentContentLimits.textCharacters {
            let pageLines = lines(of: document.page(at: index)?.string ?? "", characters: AgentContentLimits.textCharacters - count)
            count += pageLines.reduce(0) { $0 + $1.count }
            collected += pageLines
        }
        guard count < AgentContentLimits.scannedPageCharacters, DispatchTime.now() < deadline,
              let page = document.page(at: 0), let drawn = drawn(page) else {
            return AgentContentSummary(kind: .pdf, status: .read, lines: collected, pages: document.pageCount)
        }
        let seen = look(at: VNImageRequestHandler(cgImage: drawn, options: [:]))
        let images = wantsImages && DispatchTime.now() < deadline ? picture(of: drawn, source: .page(1)).map { [$0] } ?? [] : []
        return AgentContentSummary(kind: .pdf, status: .read, lines: collected, pages: document.pageCount,
                                   labels: seen?.labels ?? [], foundText: seen?.text ?? [], images: images)
    }

    private static let pdfPages = 20

    /// A PDF page on white, turned as the page says, `visionEdge` pixels on its longer side.
    private static func drawn(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let size = abs(page.rotation) % 180 == 90 ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = Double(visionEdge) / max(size.width, size.height)
        guard let context = whiteContext(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()))
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    /// The longer side a scanned page is drawn at, and a picture decoded at, for Vision. At
    /// `AgentContentLimits.lookEdge` Vision misreads print of 10 to 12 points on a letter page; at this size it reads
    /// it, in no more time. The picture for a model is made from this copy at `lookEdge`.
    private static let visionEdge = 1_600

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

    /// A picture's first frame, or its primary image when it holds several, decoded by ImageIO at `visionEdge` pixels
    /// at most on its longer side and turned as its EXIF orientation says. Its size is read from its header first, and
    /// a picture of more than `mostPixels` is too large and not decoded at all. The copy is drawn from the pixels,
    /// never taken from a thumbnail stored in the file. Unreadable when ImageIO can't read its size or decode it.
    private static func firstFrame(of data: Data) -> Result<CGImage, AgentContentStatus> {
        let header = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, header), CGImageSourceGetCount(source) > 0 else {
            return .failure(.unreadable)
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let found = CGImageSourceCopyPropertiesAtIndex(source, index, header) as? [String: Any],
              let width = (found[kCGImagePropertyPixelWidth as String] as? NSNumber)?.int64Value,
              let height = (found[kCGImagePropertyPixelHeight as String] as? NSNumber)?.int64Value,
              width > 0, height > 0 else { return .failure(.unreadable) }
        guard width <= mostPixels / height else { return .failure(.too_large) }
        let copy = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: visionEdge,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, copy) else { return .failure(.unreadable) }
        return .success(image)
    }

    /// The most pixels a picture may have to be decoded: 100 megapixels.
    private static let mostPixels: Int64 = 100_000_000

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

    // MARK: Pictures for a model

    /// `image` as a JPEG for a model: drawn anew on white in sRGB, `AgentContentLimits.lookEdge` pixels at most on its
    /// longer side and never larger than it is, and written at `lookQuality` with nothing but its pixels, so nothing of
    /// a file's own bytes or metadata is in it. Nil when ImageIO still finds metadata in it.
    private static func picture(of image: CGImage, source: AgentContentImage.Source) -> AgentContentImage? {
        let longer = max(image.width, image.height)
        guard longer > 0 else { return nil }
        let scale = min(1, Double(AgentContentLimits.lookEdge) / Double(longer))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = whiteContext(width: width, height: height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let drawn = context.makeImage(),
              let written = NSBitmapImageRep(cgImage: drawn).representation(
                using: .jpeg, properties: [.compressionFactor: AgentContentLimits.lookQuality]),
              let jpeg = withoutMetadata(written), hasNoMetadata(jpeg) else { return nil }
        return AgentContentImage(jpeg: jpeg, width: width, height: height, source: source)
    }

    /// A bitmap of this size in sRGB, with no transparency, filled with white and drawn into smoothly.
    private static func whiteContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        return context
    }

    /// A JPEG with its comments and every application segment but JFIF's (APP0) and Adobe's (APP14) left out: no EXIF,
    /// GPS, TIFF, IPTC, XMP or color profile, which AppKit's writer would add, only what a decoder needs for the pixels.
    /// Nil when it isn't a JPEG this can walk.
    static func withoutMetadata(_ jpeg: Data) -> Data? {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var kept: [UInt8] = [0xFF, 0xD8]
        var at = 2
        while at + 4 <= bytes.count, bytes[at] == 0xFF {
            let marker = bytes[at + 1]
            // A fill byte before a marker.
            if marker == 0xFF { at += 1; continue }
            // A marker that stands alone has no place before the scan.
            guard marker != 0x01, !(0xD0...0xD9).contains(marker) else { return nil }
            let length = Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            guard length >= 2, at + 2 + length <= bytes.count else { return nil }
            // From the start of the scan on, the bytes are the picture itself.
            if marker == 0xDA { return Data(kept + bytes[at...]) }
            if !(0xE1...0xED).contains(marker), marker != 0xEF, marker != 0xFE { kept += bytes[at..<(at + 2 + length)] }
            at += 2 + length
        }
        return nil
    }

    /// ImageIO finds no metadata in this JPEG: no EXIF, GPS, TIFF or IPTC dictionary, and no tag at all, XMP's
    /// included.
    static func hasNoMetadata(_ jpeg: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let found = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return false }
        let dictionaries = [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary,
                            kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary]
        guard dictionaries.allSatisfy({ found[$0 as String] == nil }) else { return false }
        let tags = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCopyTags($0) as? [Any] } ?? []
        return tags.isEmpty
    }

    // MARK: Videos

    /// A video's length, and what three to five frames taken evenly through it show and say; each frame looked at is
    /// also pictured for a model when the request asks. Its bytes come only through `AgentContentVideoBytes`.
    private static func video(_ file: AgentContentFile, ext: String, wantsImages: Bool, deadline: DispatchTime) -> AgentContentSummary {
        let contentType = UTType(filenameExtension: ext)?.identifier ?? UTType.movie.identifier
        let bytes = AgentContentVideoBytes(file: file, contentType: contentType)
        guard let address = URL(string: AgentContentVideoBytes.address) else { return .notRead(.video, .unreadable) }
        // A reference movie names other media to play; none is followed, so only this file's own frames are read.
        let asset = AVURLAsset(url: address, options: [AVURLAssetReferenceRestrictionsKey:
                                                        NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)])
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
                // Each frame near its own time. Left to itself the generator gives the nearest keyframe, which in a
                // video with few of them is the first frame every time.
                let tolerance = CMTime(seconds: duration / Double(frames) / 4, preferredTimescale: 600)
                generator.requestedTimeToleranceBefore = tolerance
                generator.requestedTimeToleranceAfter = tolerance
                var best: [String: Double] = [:]
                var text: [String] = []
                var images: [AgentContentImage] = []
                var looked = 0
                for index in 0..<frames {
                    try Task.checkCancellation()
                    let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(frames), preferredTimescale: 600)
                    guard let frame = try? await generator.image(at: time),
                          let seen = look(at: VNImageRequestHandler(cgImage: frame.image, options: [:])) else { continue }
                    looked += 1
                    // Each frame's own labels, already its most certain five, so every scene is kept.
                    for label in seen.labels { best[label.identifier] = max(best[label.identifier] ?? 0, label.confidence) }
                    for line in seen.text where !text.contains(line) { text.append(line) }
                    let seconds = frame.actualTime.seconds.isFinite ? frame.actualTime.seconds : time.seconds
                    if wantsImages, let made = picture(of: frame.image, source: .frame(seconds: seconds)) { images.append(made) }
                }
                guard looked > 0 else { answer.finish(.notRead(.video, .unreadable)); return }
                let labels: [AgentContentLabel] = best.map { AgentContentLabel(identifier: $0.key, confidence: $0.value) }
                    .sorted(by: comesFirst)
                let found = lines(of: text.joined(separator: "\n"), characters: AgentContentLimits.foundTextCharacters)
                answer.finish(AgentContentSummary(kind: .video, status: .read, labels: Array(labels.prefix(AgentContentLimits.videoLabels)),
                                                  foundText: found, seconds: duration, frames: looked, images: images))
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

/// The directory of a zip, as Word (.docx) and OpenDocument (.odt) files are, read from the bytes Helm read before
/// any reader unpacks them. macOS's readers unpack each part to the size this directory gives and fail rather than go
/// past it, so these sizes bound what a file can unpack to.
enum AgentContentZip {
    /// Why a zip is refused.
    enum Refusal: Equatable {
        /// Its end record or its directory can't be read, or isn't where the end record says.
        case unreadable
        /// A Zip64 archive, whose sizes aren't in the directory's own fields.
        case zip64
        /// More than `mostParts` parts.
        case tooManyParts
        /// Its parts unpack to more than `mostBytes` in all.
        case tooLarge
        /// A part unpacks to more than `mostRatio` times its packed size, and more than `slack` bytes past that.
        case packedTooTightly
    }

    static let mostBytes = 16 * 1024 * 1024
    static let mostParts = 2_000
    static let mostRatio = 100
    /// A short part packs tightly whatever it holds, so each may unpack to this many bytes past its ratio.
    static let slack = 4 * 1024

    /// Why these bytes are refused, or nil for a zip of a size Helm reads.
    static func refusal(of data: Data) -> Refusal? {
        data.withUnsafeBytes { refusal(of: $0) }
    }

    private static func refusal(of bytes: UnsafeRawBufferPointer) -> Refusal? {
        func u16(_ at: Int) -> Int { Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt16.self))) }
        func u32(_ at: Int) -> Int { Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
        // The end record is 22 bytes and a comment that ends the file. There must be one such record, and only one.
        let ends = stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 0xFFFF), by: -1)
            .filter { u32($0) == 0x0605_4B50 && $0 + 22 + u16($0 + 20) == bytes.count }
        guard ends.count == 1, let end = ends.first else { return .unreadable }
        // Zip64 keeps its sizes in a record of its own, found through a locator just before this one, and marks each
        // field it moved there with all ones.
        if end >= 20, u32(end - 20) == 0x0706_4B50 { return .zip64 }
        let parts = u16(end + 10), size = u32(end + 12), start = u32(end + 16)
        if u16(end + 8) == 0xFFFF || parts == 0xFFFF || size == 0xFFFF_FFFF || start == 0xFFFF_FFFF { return .zip64 }
        // One disk, and the directory right before the end record.
        guard u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == parts, start + size == end else { return .unreadable }
        guard parts <= mostParts else { return .tooManyParts }
        var at = start, unpackedInAll = 0
        for _ in 0..<parts {
            guard at + 46 <= end, u32(at) == 0x0201_4B50 else { return .unreadable }
            let packed = u32(at + 20), unpacked = u32(at + 24), disk = u16(at + 34), local = u32(at + 42)
            let extra = at + 46 + u16(at + 28), extraEnd = extra + u16(at + 30), next = extraEnd + u16(at + 32)
            guard next <= end else { return .unreadable }
            if packed == 0xFFFF_FFFF || unpacked == 0xFFFF_FFFF || disk == 0xFFFF || local == 0xFFFF_FFFF { return .zip64 }
            var field = extra
            while field + 4 <= extraEnd {
                if u16(field) == 0x0001 { return .zip64 }
                field += 4 + u16(field + 2)
            }
            // The part's packed bytes lie before the directory.
            guard disk == 0, local + 30 + packed <= start else { return .unreadable }
            unpackedInAll += unpacked
            guard unpackedInAll <= mostBytes else { return .tooLarge }
            guard unpacked <= packed * mostRatio + slack else { return .packedTooTightly }
            at = next
        }
        return at == end ? nil : .unreadable
    }
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
