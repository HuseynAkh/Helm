import Foundation

extension URL {
    static let helmRecentsURL = URL(string: "helm://recent")!

    var pathComponentsFromRoot: [String] {
        let components = pathComponents
        guard components.count > 1 else { return components }
        // Skip the root "/" and return meaningful components
        return Array(components.dropFirst())
    }

    func ancestorURLs() -> [URL] {
        var urls: [URL] = []
        var current = self.standardizedFileURL
        let root = URL(fileURLWithPath: "/")

        while current != root {
            urls.insert(current, at: 0)
            current = current.deletingLastPathComponent()
        }
        urls.insert(root, at: 0)
        return urls
    }

    var isRoot: Bool {
        self.standardizedFileURL.path == "/"
    }

    var volumePath: URL? {
        try? resourceValues(forKeys: [.volumeURLKey]).volume
    }

    var isHelmVirtualLocation: Bool {
        scheme == "helm"
    }

    var isHelmRecentsLocation: Bool {
        scheme == "helm" && host == "recent"
    }
}
