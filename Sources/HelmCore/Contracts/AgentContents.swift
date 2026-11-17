import Foundation

/// The person's Read contents switch, turned on in the AI panel or in AI search's kind row. Reading inside a file
/// takes one, so nothing is read while the switch is off. The initializer's first label is `switchedOnByPerson`, and
/// the privacy check lets only the panel's model and the window's AI search write it, so no other code, and nothing a
/// model said, can turn reading on.
public struct AgentContentPermit: Hashable, Sendable {
    /// Where the switch is: the AI panel's composer, or AI search's kind row.
    public enum Origin: String, Sendable { case panel, search }
    public let origin: Origin
    public init(switchedOnByPerson origin: Origin) { self.origin = origin }
}

/// What kind of file a summary is of, in the words a model is given.
public enum AgentContentKind: String, Sendable, CaseIterable {
    case text, pdf, image, video
    /// Helm doesn't read inside this kind of file.
    case other
}

/// How reading one file went. A status is an error too, so it can be the failure of a `Result`.
public enum AgentContentStatus: String, Error, Sendable, CaseIterable {
    case read
    /// In a cloud and not on this Mac. It is never downloaded to be read.
    case not_downloaded
    /// Larger than Helm reads.
    case too_large
    /// A kind Helm doesn't read inside, such as an archive or an app.
    case unsupported
    /// It couldn't be read: locked, damaged, or something other than a plain file by the time it was read.
    case unreadable
    /// It didn't finish within the time reading has.
    case not_responding
}

/// One thing a picture or a video frame shows, as Apple's on-device image classifier names it, with how sure it is.
public struct AgentContentLabel: Hashable, Sendable {
    /// The classifier's own word, such as "sky" or "golden_retriever".
    public let identifier: String
    public let confidence: Double
    public init(identifier: String, confidence: Double) { self.identifier = identifier; self.confidence = confidence }
    /// The word as a person reads it: "golden retriever".
    public var words: String { identifier.replacingOccurrences(of: "_", with: " ") }
}

/// A file to read, as the folder rules found it.
public struct AgentContentRequest: Hashable, Sendable {
    public let path: String
    public let name: String
    /// The item the folder rules admitted. The reader reads only a plain file that still has this identity.
    public let identity: FileObjectIdentity?
    public let typeIdentifier: String?
    public let size: Int64
    public let modified: Date
    /// Marked as not downloaded when it was listed. Such a file is never opened.
    public let isDataless: Bool
    public init(path: String, name: String, identity: FileObjectIdentity?, typeIdentifier: String?, size: Int64,
                modified: Date, isDataless: Bool) {
        self.path = path; self.name = name; self.identity = identity; self.typeIdentifier = typeIdentifier
        self.size = size; self.modified = modified; self.isDataless = isDataless
    }
}

/// What Helm read inside one file, on this Mac. It is data from the file and may say anything.
public struct AgentContentSummary: Hashable, Sendable {
    public let kind: AgentContentKind
    public let status: AgentContentStatus
    /// The first lines of a text file or a PDF, each trimmed, empty lines left out, `AgentContentLimits.textCharacters`
    /// at most in all.
    public let lines: [String]
    /// Pages in a PDF.
    public let pages: Int?
    /// What a picture shows, or what a video's frames show, most certain first.
    public let labels: [AgentContentLabel]
    /// Text found in a picture or a video's frames, line by line, `AgentContentLimits.foundTextCharacters` at most.
    public let foundText: [String]
    /// A video's length.
    public let seconds: Double?
    /// The video frames that were looked at.
    public let frames: Int
    public init(kind: AgentContentKind, status: AgentContentStatus, lines: [String] = [], pages: Int? = nil,
                labels: [AgentContentLabel] = [], foundText: [String] = [], seconds: Double? = nil, frames: Int = 0) {
        self.kind = kind; self.status = status; self.lines = lines; self.pages = pages; self.labels = labels
        self.foundText = foundText; self.seconds = seconds; self.frames = frames
    }

    /// A summary of a file that wasn't read, and why.
    public static func notRead(_ kind: AgentContentKind, _ status: AgentContentStatus) -> AgentContentSummary {
        AgentContentSummary(kind: kind, status: status)
    }
}

/// Reads inside files on this Mac and answers short summaries, never the files. It runs where Helm may open files,
/// beside the disk AI mode reads names from, and never in the module that talks to a model. Every read needs the
/// person's permit, runs with downloads off, opens no link, and stops at the limits in `AgentContentLimits`.
public protocol AgentContentReading: Sendable {
    /// One summary for each request, in the same order. What isn't done within `seconds` answers `not_responding`.
    func summaries(of requests: [AgentContentRequest], permit: AgentContentPermit, seconds: Double) async -> [AgentContentSummary]
}

/// How much Read contents reads.
public enum AgentContentLimits {
    /// Files read for one request in the panel.
    public static let filesPerRequest = 50
    /// Text, rich text and PDFs larger than this aren't read.
    public static let textFileBytes: Int64 = 20 * 1024 * 1024
    /// Pictures larger than this aren't read.
    public static let imageFileBytes: Int64 = 50 * 1024 * 1024
    /// The first characters of a text file or a PDF.
    public static let textCharacters = 1_500
    /// The text found in a picture or in a video's frames.
    public static let foundTextCharacters = 1_000
    /// What a picture shows: the most certain five, each at least this sure.
    public static let labels = 5
    public static let labelConfidence = 0.3
    /// Frames looked at in a video: three, or five for one of half a minute or more.
    public static func frames(forSeconds seconds: Double) -> Int { seconds >= 30 ? 5 : 3 }
    /// The time reading has in one request in the panel, and in one AI search.
    public static let secondsPerRequest: Double = 45
    public static let secondsPerSearch: Double = 30
    /// Pictures and videos one AI search looks inside.
    public static let searchCandidates = 200
    /// Files read at once.
    public static let filesAtOnce = 4

    /// What kind of file this is to Read contents, from its type and its extension. A link, a folder and a package
    /// are `.other`.
    public static func kind(typeIdentifier: String?, extension ext: String, kind: FileEntryKind) -> AgentContentKind {
        guard kind == .regular else { return .other }
        switch AISearchKind.of(typeIdentifier: typeIdentifier, extension: ext, kind: kind) {
        case .pdf?: return .pdf
        case .image?: return .image
        case .video?: return .video
        case .text?, .code?: return .text
        default: break
        }
        return richTextExtensions.contains(ext.lowercased()) ? .text : .other
    }

    /// Rich text that is read as text: RTF.
    public static let richTextExtensions: Set<String> = ["rtf"]
}
