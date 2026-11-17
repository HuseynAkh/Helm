import Foundation

/// The kinds of file a model may ask for and be told about, and the one table that decides them.
/// Listings for a model, its searches, the matcher and the Spotlight predicates all read this table, so a file is the
/// same kind everywhere. It is a plain table of extensions and type identifiers: nothing is asked of the system.
public enum AISearchKind: String, Sendable, CaseIterable {
    case folder, document, pdf, image, video, audio, text, code, spreadsheet, presentation, archive, app, font

    /// The kind of one item, or nil when the table has no word for it. A link, an alias and a device have none.
    /// The extension decides first, since it is what the person sees; the type identifier settles a file whose
    /// extension the table doesn't know. `ext` may come with or without its dot, in any case.
    public static func of(typeIdentifier: String?, extension ext: String, kind: FileEntryKind) -> AISearchKind? {
        switch kind {
        case .directory: return .folder
        case .symlinkToDirectory, .symlinkToFile, .danglingSymlink, .alias, .other: return nil
        case .regular, .package: break
        }
        let ext = (ext.hasPrefix(".") ? String(ext.dropFirst()) : ext).lowercased()
        let identifier = typeIdentifier?.lowercased()
        // An app is a package. A plain file that happens to end in ".app" isn't one.
        if kind == .package, ext == "app" || identifier.map({ applicationIdentifiers.contains($0) }) == true { return .app }
        if let found = kindByExtension[ext] { return found }
        guard let identifier else { return nil }
        if let found = kindByIdentifier[identifier] { return found }
        return family(of: identifier)
    }

    /// The type identifiers Spotlight is asked for: an item is this kind when its type tree holds one of them.
    /// `document` is the wide kind, so its list takes in pdf, text, spreadsheet and presentation too.
    public var typeIdentifiers: [String] {
        switch self {
        case .folder: return ["public.folder"]
        case .document: return ["public.composite-content", "public.text", "com.adobe.pdf", "public.spreadsheet", "public.presentation"]
        case .pdf: return ["com.adobe.pdf"]
        case .image: return ["public.image"]
        case .video: return ["public.movie"]
        case .audio: return ["public.audio"]
        case .text: return ["public.text"]
        case .code: return ["public.source-code", "public.html", "public.css"]
        case .spreadsheet: return ["public.spreadsheet", "public.comma-separated-values-text", "public.tab-separated-values-text"]
        case .presentation: return ["public.presentation"]
        case .archive: return ["public.archive", "public.disk-image"]
        case .app: return ["com.apple.application"]
        case .font: return ["public.font"]
        }
    }

    /// Whether an item whose kind is `other` answers a request for this kind. Every kind answers for itself, and
    /// `document` also takes in pdf, text, spreadsheet and presentation, as its type identifiers do.
    public func covers(_ other: AISearchKind) -> Bool {
        if self == other { return true }
        return self == .document && [.pdf, .text, .spreadsheet, .presentation].contains(other)
    }

    /// The kinds the AI search's kind row offers after Any, in its order: Photo, Video, Document, Folder, Code, Audio
    /// and Archive. Photo is `image`, and Document takes in the kinds `covers` gives it.
    public static let searchChoices: [AISearchKind] = [.image, .video, .document, .folder, .code, .audio, .archive]

    // MARK: The table

    /// Extensions in lower case, without the dot. An extension appears under one kind only.
    static let extensions: [(kind: AISearchKind, extensions: [String])] = [
        (.pdf, ["pdf"]),
        (.image, ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "svg", "psd", "raw", "cr2", "cr3",
                  "nef", "arw", "dng", "orf", "rw2", "raf", "ico", "icns", "avif", "jp2", "tga"]),
        (.video, ["mp4", "m4v", "mov", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp", "m2ts", "mts"]),
        (.audio, ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "oga", "opus", "wma", "caf", "mid", "midi", "m4b", "m4r"]),
        (.text, ["txt", "text", "md", "markdown", "log", "json", "yaml", "yml", "xml", "toml", "ini", "cfg", "conf", "tex", "srt"]),
        // "ts" is TypeScript here. macOS reads it as a video stream, which a folder of source files never is.
        (.code, ["swift", "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "java", "kt", "kts", "py", "rb", "js", "mjs", "cjs",
                 "jsx", "ts", "tsx", "go", "rs", "php", "pl", "sh", "bash", "zsh", "fish", "lua", "r", "scala", "cs", "sql",
                 "html", "htm", "css", "scss", "sass", "less", "vue", "svelte", "dart", "ex", "exs", "erl", "hs", "clj", "asm",
                 "s", "ps1", "bat", "gradle", "cmake", "ipynb"]),
        (.spreadsheet, ["xls", "xlsx", "xlsm", "numbers", "ods", "csv", "tsv"]),
        (.presentation, ["ppt", "pptx", "pps", "ppsx", "key", "odp"]),
        (.document, ["doc", "docx", "docm", "odt", "pages", "rtf", "rtfd", "wpd", "epub"]),
        (.archive, ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "7z", "rar", "cpio", "xar", "z", "jar",
                    "dmg", "iso", "img", "sparseimage", "pkg"]),
        (.font, ["ttf", "otf", "ttc", "otc", "woff", "woff2", "dfont"])
    ]

    /// Text that reads as prose, whatever kind a search is kept to: plain text, Markdown, RTF, logs, subtitles and
    /// TeX. The rest of `text`, such as settings in JSON or YAML, is nearer to code.
    public static let proseExtensions: Set<String> = ["txt", "text", "md", "markdown", "rtf", "log", "srt", "tex"]

    /// Type identifiers in lower case, for a file whose extension the table doesn't know.
    static let identifiers: [(kind: AISearchKind, identifiers: [String])] = [
        (.pdf, ["com.adobe.pdf"]),
        (.image, ["public.image", "public.jpeg", "public.png", "public.heic", "public.heif", "public.tiff", "com.compuserve.gif",
                  "com.microsoft.bmp", "public.svg-image", "org.webmproject.webp", "com.adobe.photoshop-image",
                  "public.camera-raw-image", "com.apple.icns", "com.microsoft.ico"]),
        (.video, ["public.movie", "public.video", "public.mpeg-4", "public.mpeg", "public.avi", "com.apple.quicktime-movie",
                  "com.apple.m4v-video", "org.matroska.mkv", "org.webmproject.webm", "public.mpeg-2-transport-stream"]),
        (.audio, ["public.audio", "public.mp3", "public.mpeg-4-audio", "com.apple.m4a-audio", "com.microsoft.waveform-audio",
                  "public.aiff-audio", "public.aifc-audio", "org.xiph.flac", "com.apple.coreaudio-format", "public.midi-audio"]),
        (.text, ["public.text", "public.plain-text", "public.utf8-plain-text", "public.utf16-plain-text",
                 "net.daringfireball.markdown", "public.json", "public.yaml", "public.xml", "public.toml", "public.log", "com.apple.log"]),
        (.code, ["public.source-code", "public.script", "public.shell-script", "public.python-script", "public.ruby-script",
                 "public.perl-script", "public.php-script", "public.swift-source", "public.c-source", "public.c-header",
                 "public.c-plus-plus-source", "public.c-plus-plus-header", "public.objective-c-source",
                 "public.objective-c-plus-plus-source", "public.assembly-source", "com.netscape.javascript-source",
                 "com.sun.java-source", "public.html", "public.css"]),
        (.spreadsheet, ["public.spreadsheet", "com.microsoft.excel.xls", "org.openxmlformats.spreadsheetml.sheet",
                        "com.apple.iwork.numbers.numbers", "com.apple.iwork.numbers.sffnumbers",
                        "org.oasis-open.opendocument.spreadsheet", "public.comma-separated-values-text",
                        "public.tab-separated-values-text"]),
        (.presentation, ["public.presentation", "com.microsoft.powerpoint.ppt", "org.openxmlformats.presentationml.presentation",
                         "com.apple.iwork.keynote.key", "com.apple.iwork.keynote.sffkey",
                         "org.oasis-open.opendocument.presentation"]),
        (.document, ["public.composite-content", "com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
                     "com.apple.iwork.pages.pages", "com.apple.iwork.pages.sffpages", "org.oasis-open.opendocument.text",
                     "public.rtf", "com.apple.rtfd", "com.apple.flat-rtfd", "org.idpf.epub-container"]),
        (.archive, ["public.archive", "public.zip-archive", "public.tar-archive", "public.bzip2-archive", "org.gnu.gnu-zip-archive",
                    "org.7-zip.7-zip-archive", "com.rarlab.rar-archive", "com.sun.java-archive", "public.disk-image",
                    "com.apple.disk-image", "com.apple.disk-image-udif", "public.iso-image", "com.apple.installer-package-archive"]),
        (.font, ["public.font", "public.truetype-font", "public.truetype-ttf-font", "public.truetype-collection-font",
                 "public.opentype-font", "org.w3.woff", "org.w3.woff2"])
    ]

    private static let applicationIdentifiers: Set<String> = ["com.apple.application", "com.apple.application-bundle"]

    private static let kindByExtension: [String: AISearchKind] = {
        var table: [String: AISearchKind] = [:]
        for row in extensions { for ext in row.extensions where table[ext] == nil { table[ext] = row.kind } }
        return table
    }()

    private static let kindByIdentifier: [String: AISearchKind] = {
        var table: [String: AISearchKind] = [:]
        for row in identifiers { for identifier in row.identifiers where table[identifier] == nil { table[identifier] = row.kind } }
        return table
    }()

    /// Identifiers name their family in their last word, such as "com.canon.cr2-raw-image". A disk image is an
    /// archive, so it is read before the picture kinds.
    private static func family(of identifier: String) -> AISearchKind? {
        if identifier.contains("disk-image") || identifier.hasSuffix("-archive") { return .archive }
        if identifier.hasSuffix("-image") { return .image }
        if identifier.hasSuffix("-movie") || identifier.hasSuffix("-video") { return .video }
        if identifier.hasSuffix("-audio") { return .audio }
        if identifier.hasSuffix("-source") || identifier.hasSuffix("-script") || identifier.hasSuffix("-header") { return .code }
        if identifier.hasSuffix("-font") { return .font }
        if identifier.hasSuffix("-text") { return .text }
        return nil
    }
}

/// Which of a file's dates a query is about. `any` is any of the four.
public enum AISearchDateField: String, Sendable { case none, any, modified, created, added, opened }

/// The order the person asked for. `relevance` leaves the order to the ranking.
public enum AISearchSort: String, Sendable { case relevance, newest, oldest, largest, smallest }

/// One search a model planned, as typed fields. It never holds a query string: Helm builds those from the fields.
public struct AISearchQuery: Hashable, Sendable {
    public var nameAll: [String], nameAny: [String], contentAll: [String], folderAny: [String]
    public var kinds: [AISearchKind], extensions: [String]
    public var dateField: AISearchDateField, dateFrom: Date?, dateTo: Date?
    /// Sizes in bytes. 0 means none.
    public var sizeMinBytes: Int64, sizeMaxBytes: Int64

    public init(nameAll: [String] = [], nameAny: [String] = [], contentAll: [String] = [], folderAny: [String] = [],
                kinds: [AISearchKind] = [], extensions: [String] = [], dateField: AISearchDateField = .none,
                dateFrom: Date? = nil, dateTo: Date? = nil, sizeMinBytes: Int64 = 0, sizeMaxBytes: Int64 = 0) {
        self.nameAll = nameAll; self.nameAny = nameAny; self.contentAll = contentAll; self.folderAny = folderAny
        self.kinds = kinds; self.extensions = extensions; self.dateField = dateField
        self.dateFrom = dateFrom; self.dateTo = dateTo
        self.sizeMinBytes = sizeMinBytes; self.sizeMaxBytes = sizeMaxBytes
    }

    /// The most words kept in one field.
    static let wordsPerField = 8
    /// The longest word kept, in characters.
    static let wordLength = 32

    /// The query with everything a model wrote cut down to what Helm will run.
    /// Each field keeps at most eight words, and a word is kept only when it is one token (`isToken`), so no phrase a
    /// model wrote can reach a search, a status line or a reason. A word to look for inside files is kept only when
    /// the person typed it in `request`, compared without case or accents: a model can widen a search by name, but
    /// can't use one to learn which files hold words it chose.
    public func clamped(request: String) -> AISearchQuery {
        var query = self
        query.nameAll = Self.words(nameAll)
        query.nameAny = Self.words(nameAny)
        query.folderAny = Self.words(folderAny)
        let typed = Self.typedWords(of: request)
        query.contentAll = Self.words(contentAll.filter { typed.contains(Self.folded($0)) })
        query.extensions = Self.words(extensions.map { ($0.hasPrefix(".") ? String($0.dropFirst()) : $0).lowercased() })
        var seen: Set<AISearchKind> = []
        query.kinds = Array(kinds.filter { seen.insert($0).inserted }.prefix(Self.wordsPerField))
        // Dates mean something only with a field to read them from, and in order.
        if query.dateField == .none || (query.dateFrom == nil && query.dateTo == nil) {
            query.dateField = .none; query.dateFrom = nil; query.dateTo = nil
        } else if let from = query.dateFrom, let to = query.dateTo, from > to {
            query.dateFrom = to; query.dateTo = from
        }
        query.sizeMinBytes = max(0, sizeMinBytes); query.sizeMaxBytes = max(0, sizeMaxBytes)
        if query.sizeMaxBytes > 0, query.sizeMinBytes > query.sizeMaxBytes {
            (query.sizeMinBytes, query.sizeMaxBytes) = (query.sizeMaxBytes, query.sizeMinBytes)
        }
        return query
    }

    /// The query kept to the one kind the person chose in the kind row, which nothing a model answers can widen.
    /// Its kinds become the ones `kind` covers, or `kind` itself when it named none of those or no kind at all, and
    /// an extension stays only when the table puts it under a kind `kind` covers. A narrower kind a model chose, such
    /// as PDF for Document, stays. Every other field is left as it is.
    public func limited(to kind: AISearchKind) -> AISearchQuery {
        var query = self
        let covered = kinds.filter { kind.covers($0) }
        query.kinds = covered.isEmpty ? [kind] : covered
        query.extensions = extensions.filter { ext in
            AISearchKind.of(typeIdentifier: nil, extension: ext, kind: .regular).map { kind.covers($0) } ?? false
        }
        return query
    }

    /// Whether `word` is one token: letters, digits and `. _ -`, with a letter or digit among them, at most 32
    /// characters, and nothing hidden. A space, a quote, a slash or a wildcard makes it not a token.
    public static func isToken(_ word: String) -> Bool {
        guard !word.isEmpty, word.count <= wordLength, word.unicodeScalars.count <= wordLength * 2,
              AgentTextEscaper.isClean(word) else { return false }
        var hasLetterOrDigit = false
        for scalar in word.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
                hasLetterOrDigit = true
            // Marks, so a letter written as a base and its accent is still a letter.
            case .nonspacingMark, .spacingMark: break
            default: guard scalar == "." || scalar == "_" || scalar == "-" else { return false }
            }
        }
        return hasLetterOrDigit
    }

    /// The tokens among `words`, in order, each once whatever its case or accents, and no more than a field holds.
    private static func words(_ words: [String]) -> [String] {
        var seen: Set<String> = []
        return Array(words.filter { isToken($0) && seen.insert(folded($0)).inserted }.prefix(wordsPerField))
    }

    /// Every word the person typed, folded. A run such as "e-mail" counts whole and as its parts, so either may be
    /// looked for inside files.
    private static func typedWords(of request: String) -> Set<String> {
        var found: Set<String> = []
        let isPart: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        for run in request.split(whereSeparator: { !(isPart($0) || $0 == "." || $0 == "_" || $0 == "-") }) {
            let whole = run.drop(while: { !isPart($0) })
            if let end = whole.lastIndex(where: isPart) { found.insert(folded(String(whole[...end]))) }
            for part in run.split(whereSeparator: { !isPart($0) }) { found.insert(folded(String(part))) }
        }
        return found
    }

    private static func folded(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// What a model planned for one request: how to order the results, and the searches to run.
public struct AISearchPlan: Hashable, Sendable {
    public var sort: AISearchSort
    /// One to six once clamped, strictest first.
    public var queries: [AISearchQuery]
    public init(sort: AISearchSort, queries: [AISearchQuery]) { self.sort = sort; self.queries = queries }

    /// The plan with every query kept to `kind` (`AISearchQuery.limited(to:)`), in order. Two queries that differ
    /// only in what was taken away become one.
    public func limited(to kind: AISearchKind) -> AISearchPlan {
        var kept: [AISearchQuery] = []
        for query in queries.map({ $0.limited(to: kind) }) where !kept.contains(query) { kept.append(query) }
        return AISearchPlan(sort: sort, queries: kept)
    }
}

/// What about a result matched. A model answers with these codes only; the words shown come from Helm.
public enum SearchReasonCode: String, Sendable, CaseIterable { case name, content, kind, date, folder, size }

/// What Read contents found in a file that answered a search. Read on this Mac, a picture or a video that answered
/// every word a search looks for inside files: the words found in the text it holds, and the things it shows that
/// answered a word, in the classifier's own words. Looked at by a model, a file it said fits, with the short phrase
/// it gave of what the file shows or says.
public struct AISearchSighting: Hashable, Sendable {
    public enum Medium: String, Sendable { case image, video, document }
    public let medium: Medium
    public let textWords: [String]
    public let labels: [String]
    /// What a model that looked at the file said it shows or says: plain text of 80 characters at most, as
    /// `AISearchSession` cleaned it. Nil for what was read on this Mac alone.
    public let seen: String?
    public init(medium: Medium, textWords: [String], labels: [String], seen: String? = nil) {
        self.medium = medium; self.textWords = textWords; self.labels = labels; self.seen = seen
    }
}

/// Why one result matched, as facts Helm can back.
public struct SearchReason: Hashable, Sendable {
    public var codes: [SearchReasonCode]
    /// Written by Helm from what matched, such as "Mentions “plumber” · Modified 14 Mar".
    public var line: String
    public init(codes: [SearchReasonCode], line: String) { self.codes = codes; self.line = line }
}

/// What a model added to the search on show.
public struct SearchAssist: Equatable, Sendable {
    public enum Phase: String, Sendable { case thinking, done, failed }
    /// How much of the place the search could cover: all of it, only what is on this Mac, or names alone.
    public enum Coverage: String, Sendable { case full, onThisMacOnly, namesOnly }
    public var phase: Phase
    public var reasons: [ItemID: SearchReason]
    /// How the request was read, for the status bar: "12 matches · PDF · “invoice” · Mar–Jun 2026".
    public var readAs: String?
    /// Every query that ran, each written the same way, for the status bar's list.
    public var queriesRead: [String]
    public var coverage: Coverage
    public init(phase: Phase, reasons: [ItemID: SearchReason] = [:], readAs: String? = nil, queriesRead: [String] = [],
                coverage: Coverage = .full) {
        self.phase = phase; self.reasons = reasons; self.readAs = readAs
        self.queriesRead = queriesRead; self.coverage = coverage
    }
}

/// What the status bar shows during and after a search a model helped with.
public struct AISearchStatus: Equatable, Sendable {
    public var text: String
    /// The queries that ran. While this is empty the line is plain text, with nothing to press.
    public var queries: [String]
    public init(text: String, queries: [String] = []) { self.text = text; self.queries = queries }
}
