import Foundation

/// Where File › New Window opens (P-017). Finder offers a folder; Nautilus opens Home.
public enum NewWindowLocation: String, CaseIterable, Sendable {
    case current, home, desktop, documents, downloads

    public var title: String {
        switch self {
        case .current: return "Same Folder as the Front Window"
        case .home: return "Home"
        case .desktop: return "Desktop"
        case .documents: return "Documents"
        case .downloads: return "Downloads"
        }
    }
    /// The folder a new window shows, given the front window's folder and Home.
    public func folder(current: URL?, home: URL) -> URL {
        switch self {
        case .current: return current ?? home
        case .home: return home
        case .desktop: return home.appendingPathComponent("Desktop", isDirectory: true)
        case .documents: return home.appendingPathComponent("Documents", isDirectory: true)
        case .downloads: return home.appendingPathComponent("Downloads", isDirectory: true)
        }
    }
}
