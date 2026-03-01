import Foundation

struct Tab: Identifiable, Hashable {
    let id: UUID
    var title: String
    var url: URL

    init(url: URL) {
        self.id = UUID()
        self.title = Tab.makeTitle(for: url)
        self.url = url
    }

    mutating func update(url: URL) {
        self.url = url
        self.title = Tab.makeTitle(for: url)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Tab, rhs: Tab) -> Bool {
        lhs.id == rhs.id
    }

    private static func makeTitle(for url: URL) -> String {
        if url.isHelmRecentsLocation {
            return "Recent"
        }
        if url.path == "/" {
            return "/"
        }
        let component = url.lastPathComponent
        return component.isEmpty ? url.path : component
    }
}
