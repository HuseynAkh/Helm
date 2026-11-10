#if os(macOS)
import XCTest
import HelmCore
import HelmPersistence
import HelmSearch
@testable import HelmUI

/// Hunt: Settings controls do what they say, and a pane shows a setting changed anywhere else.
@MainActor final class HuntSidebarSettingsPaneTests: XCTestCase {
    private final class Memory: KeyValueStoring {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any, forKey key: String) { values[key] = value }
        func register(defaults: [String: Any]) { values.merge(defaults) { old, _ in old } }
    }

    /// ⌘+ in a window, or ⌘⇧. for hidden files, writes the setting straight to the store. Every pane follows,
    /// including one already open, without switching panes or reopening Settings.
    func testAPaneFollowsSettingsChangedElsewhere() {
        let store = SettingsStore(storage: Memory())
        let pane = SettingsSnapshotModel(store: store)
        XCTAssertFalse(pane.snapshot.bool(.showHiddenFiles))
        store.set(.bool(true), for: .showHiddenFiles)
        XCTAssertTrue(pane.snapshot.bool(.showHiddenFiles), "The pane still shows hidden files off")
        store.set(.double(15.4), for: .fileTextSize)
        XCTAssertEqual(pane.snapshot.double(.fileTextSize), 15.4)
        // The pane's own change shows what the store kept, which may be adjusted.
        pane.set(.integer(5_000), for: .searchResultLimit)
        XCTAssertEqual(pane.snapshot.integer(.searchResultLimit), 800)
    }

    private func query(_ home: URL) -> SearchQuery {
        SearchQuery(text: "notes", scope: .currentFolder(home), bookmarkPaths: [], homeDirectory: home, lastDirectory: nil,
                    showHidden: false, limit: 300)
    }
    private func candidate(_ path: String, daysOld: Double) -> SearchCandidate {
        SearchCandidate(entry: FileEntry(url: URL(fileURLWithPath: path), kind: .regular,
                                         modificationDate: Date(timeIntervalSinceNow: -daysOld * 86_400)))
    }

    /// Settings › Search › "Show results from Home first" and "Include system folders" decide how
    /// results are ordered.
    func testSearchOrderFollowsSettingsSearch() {
        let home = URL(fileURLWithPath: "/Users/helm", isDirectory: true)
        let old = candidate("/Users/helm/Documents/notes.txt", daysOld: 400)
        let new = candidate("/Users/helm/Templates/notes.txt", daysOld: 0.1)
        func first(_ settings: SettingsSnapshot, _ candidates: [SearchCandidate]) -> String? {
            let context = HostEffectRunner.rankingContext(query(home), settings: settings)
            return SearchRanker.rank(candidates, context: context).results.first?.entry.url.path
        }
        // On, as it starts out: your own folders come first, even with an older file.
        XCTAssertEqual(first(SettingsSnapshot(), [old, new]), old.entry.url.path)
        // Off: the newer file comes first.
        let notPreferred = SettingsSnapshot(values: [SettingKey.searchPreferUserFolders.rawValue: .bool(false)])
        XCTAssertEqual(HostEffectRunner.rankingContext(query(home), settings: notPreferred).preferredRoots, [])
        XCTAssertEqual(first(notPreferred, [old, new]), new.entry.url.path)
        // macOS's own folders sink below your files unless they're included.
        let system = candidate("/Library/Application Support/notes.txt", daysOld: 0.1)
        let elsewhere = candidate("/Volumes/Backup/notes.txt", daysOld: 30)
        XCTAssertEqual(first(SettingsSnapshot(), [system, elsewhere]), elsewhere.entry.url.path)
        let included = SettingsSnapshot(values: [SettingKey.searchIncludeSystemLocations.rawValue: .bool(true)])
        XCTAssertTrue(HostEffectRunner.rankingContext(query(home), settings: included).includeSystemLocations)
        XCTAssertEqual(first(included, [system, elsewhere]), system.entry.url.path)
    }
}
#endif
