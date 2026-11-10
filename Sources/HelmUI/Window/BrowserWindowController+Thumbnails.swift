#if os(macOS)
import AppKit
import HelmCore

/// What the grid shows for one picture, for tests and scripted runs, since nobody is there to look.
public struct GridThumbnailReport: Equatable {
    public let name: String
    /// "thumbnail" once its own preview is on show; otherwise "quick preview", "file icon", "type icon",
    /// "another image", "no image" or "not on show".
    public let shows: String
    public init(name: String, shows: String) { self.name = name; self.shows = shows }
    public var hasThumbnail: Bool { shows == "thumbnail" }
}

extension BrowserWindowController {
    /// What the grid shows for each picture in the folder on show, in its order, or nil while the grid isn't on show.
    public func gridThumbnailsForTesting() -> [GridThumbnailReport]? {
        (shownContent as? FileGridController)?.thumbnailsForTesting()
    }
}
#endif
