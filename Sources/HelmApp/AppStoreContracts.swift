// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmPersistence

/// Shared store lifetime and explicit quit flush preserve F-028–F-030/F-068.
@MainActor public protocol AppFlushable: AnyObject { func flush() async throws }
/// Bookmark seam retains offline paths (F-028, B-029).
@MainActor public protocol AppBookmarkStoring: AppFlushable {
    var records: [BookmarkRecord] { get }
    var changes: Broadcast<[BookmarkRecord]> { get }
    @discardableResult func add(_ url: URL, isDirectory: Bool, at date: Date) -> Bool
    func remove(path: String)
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
