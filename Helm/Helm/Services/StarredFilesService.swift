import Foundation

final class StarredFilesService: @unchecked Sendable {

    private let userDefaultsKey = "com.helm.starredFiles"
    private var starredURLs: Set<URL>
    private let lock = NSLock()

    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let urls = try? JSONDecoder().decode([URL].self, from: data) {
            self.starredURLs = Set(urls)
        } else {
            self.starredURLs = []
        }
    }

    func isStarred(url: URL) -> Bool {
        lock.withLock {
            starredURLs.contains(url.standardizedFileURL)
        }
    }

    func toggleStar(url: URL) {
        lock.withLock {
            let standardized = url.standardizedFileURL
            if starredURLs.contains(standardized) {
                starredURLs.remove(standardized)
            } else {
                starredURLs.insert(standardized)
            }
            persist()
        }
    }

    func star(url: URL) {
        lock.withLock {
            starredURLs.insert(url.standardizedFileURL)
            persist()
        }
    }

    func unstar(url: URL) {
        lock.withLock {
            starredURLs.remove(url.standardizedFileURL)
            persist()
        }
    }

    func allStarred() -> [URL] {
        lock.withLock {
            Array(starredURLs).filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private func persist() {
        let urls = Array(starredURLs)
        if let data = try? JSONEncoder().encode(urls) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }
}
