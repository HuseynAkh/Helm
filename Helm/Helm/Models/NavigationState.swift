import Foundation
import Combine

final class NavigationState: ObservableObject {
    @Published private(set) var backStack: [NavigationEntry] = []
    @Published private(set) var forwardStack: [NavigationEntry] = []
    @Published private(set) var currentURL: URL
    @Published var currentSelectedItems: Set<URL> = []

    struct NavigationEntry {
        let url: URL
        let selectedItems: Set<URL>
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    init(initialURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentURL = initialURL
    }

    func navigateTo(_ url: URL) {
        let entry = NavigationEntry(url: currentURL, selectedItems: currentSelectedItems)
        backStack.append(entry)
        forwardStack.removeAll()
        currentURL = url
        currentSelectedItems = []
    }

    @discardableResult
    func goBack() -> NavigationEntry? {
        guard let entry = backStack.popLast() else { return nil }
        let forwardEntry = NavigationEntry(url: currentURL, selectedItems: currentSelectedItems)
        forwardStack.append(forwardEntry)
        currentURL = entry.url
        currentSelectedItems = entry.selectedItems
        return entry
    }

    @discardableResult
    func goForward() -> NavigationEntry? {
        guard let entry = forwardStack.popLast() else { return nil }
        let backEntry = NavigationEntry(url: currentURL, selectedItems: currentSelectedItems)
        backStack.append(backEntry)
        currentURL = entry.url
        currentSelectedItems = entry.selectedItems
        return entry
    }

    func goUp() -> URL? {
        let parent = currentURL.deletingLastPathComponent()
        guard parent != currentURL else { return nil }
        navigateTo(parent)
        return parent
    }
}
