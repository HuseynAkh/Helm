import Foundation
import HelmCore

/// Shared store lifetime and explicit quit flush preserve F-028–F-030/F-068.
@MainActor public protocol AppFlushable: AnyObject { func flush() async throws }
/// Bookmark seam retains offline paths (F-028, B-029).
@MainActor public protocol AppBookmarkStoring: AppFlushable {
    var records: [BookmarkRecord] { get }
    var changes: Broadcast<[BookmarkRecord]> { get }
    @discardableResult func add(_ url: URL, isDirectory: Bool, at date: Date) -> Bool
    func remove(path: String)
    /// Adds a bookmark at a position in the list, as dropping between two bookmarks does (P-188).
    @discardableResult func insert(_ url: URL, isDirectory: Bool, at index: Int, date: Date) -> Bool
    /// Moves a bookmark to a position, counted in the list as it is before the move.
    func move(path: String, to index: Int)
}
public extension AppBookmarkStoring {
    @discardableResult func insert(_ url: URL, isDirectory: Bool, at index: Int, date: Date) -> Bool {
        add(url, isDirectory: isDirectory, at: date)
    }
    func move(path: String, to index: Int) {}
}

/// Where a bookmark moved from `from` to before position `index` ends up once it's out of the list.
public enum BookmarkOrder {
    public static func moved<T>(_ items: [T], from: Int, to index: Int) -> [T] {
        guard items.indices.contains(from) else { return items }
        var next = items
        let item = next.remove(at: from)
        let target = min(max(0, from < index ? index - 1 : index), next.count)
        next.insert(item, at: target)
        return next
    }
}
/// A single star service is shared across windows (F-029, B-027).
@MainActor public protocol AppStarStoring: AppFlushable {
    var records: [StarRecord] { get }
    var changes: Broadcast<[StarRecord]> { get }
    func isStarred(_ url: URL) -> Bool
    func star(_ url: URL, at date: Date)
    func unstar(_ url: URL)
}
/// Recent provider remains injectable into filesystem services (F-030).
@MainActor public protocol AppRecentStoring: AppFlushable, RecentRecordsProviding {
    var records: [RecentRecord] { get }
    var changes: Broadcast<[RecentRecord]> { get }
    func recordAccess(to url: URL, kind: FileEntryKind, at date: Date)
    func clear()
}
/// Window snapshots share one document (F-068).
@MainActor public protocol AppSessionStoring: AppFlushable {
    var windows: [SessionWindow] { get }
    var changes: Broadcast<[SessionWindow]> { get }
    func replace(windows: [SessionWindow])
}
/// Put Back records only known origins (F-060).
@MainActor public protocol AppTrashOriginStoring: AppFlushable, TrashOriginRecording {}

extension BookmarkStore: AppBookmarkStoring {}
extension StarStore: AppStarStoring {}
extension RecentStore: AppRecentStoring {}
extension SessionStore: AppSessionStoring {}
extension TrashOriginStore: AppTrashOriginStoring {}
