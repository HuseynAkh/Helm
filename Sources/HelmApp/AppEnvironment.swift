// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmFileSystem
import HelmPersistence
import HelmOperations

/// Reject non-file roots before constructing stores (F-068, B-068).
public enum AppConfigurationError: Error, Sendable { case nonFileDirectory }

/// Injected roots avoid real-home access in tests (F-068, B-068).
public struct AppDirectories: Equatable, Sendable {
    public let home: URL
    public let applicationSupport: URL
    public let volumeRoots: [URL]
    public init(home: URL, applicationSupport: URL, volumeRoots: [URL] = []) {
        self.home = home; self.applicationSupport = applicationSupport; self.volumeRoots = volumeRoots
    }
}
/// All flush failures are returned together; one failed document cannot skip the others (F-068).
public struct AppFlushFailure: Error, Equatable, Sendable {
    public let document: String
    public let message: String
    public init(document: String, message: String) { self.document = document; self.message = message }
}

/// One composition root per application shares stores and the journal across windows (B-027, B-105).
@MainActor public final class AppEnvironment {
    public let settings: SettingsStore
    public let bookmarks: any AppBookmarkStoring
    public let stars: any AppStarStoring
    public let recents: any AppRecentStoring
    public let session: any AppSessionStoring
    public let trashOrigins: any AppTrashOriginStoring
    public let tagCatalog: any AppTagCatalogStoring
    public let viewOptions: any AppViewOptionsStoring
    public let fileSystem: any FileSystem
    public let journal: OperationJournal
    public let clock: any HelmClock
    public let directories: AppDirectories

    public init(settings: SettingsStore, bookmarks: any AppBookmarkStoring, stars: any AppStarStoring,
                recents: any AppRecentStoring, session: any AppSessionStoring, trashOrigins: any AppTrashOriginStoring,
                tagCatalog: any AppTagCatalogStoring, viewOptions: any AppViewOptionsStoring,
                fileSystem: any FileSystem, journal: OperationJournal, clock: any HelmClock, directories: AppDirectories) {
        self.settings = settings; self.bookmarks = bookmarks; self.stars = stars; self.recents = recents
        self.session = session; self.trashOrigins = trashOrigins; self.fileSystem = fileSystem
        self.tagCatalog = tagCatalog; self.viewOptions = viewOptions
        self.journal = journal; self.clock = clock; self.directories = directories
    }

    /// Migration must succeed before defaults registration or any store is exposed (F-068, B-029).
    public static func live(directories: AppDirectories, settingsStorage: any KeyValueStoring,
                            legacyReader: any LegacyDefaultsReading, clock: any HelmClock = SystemHelmClock(),
                            bundleDomain: String = "com.helm.filemanager") async throws -> AppEnvironment {
        guard directories.home.isFileURL, directories.applicationSupport.isFileURL,
              directories.volumeRoots.allSatisfy(\.isFileURL) else { throw AppConfigurationError.nonFileDirectory }
        let locations = StoreLocation(directory: directories.applicationSupport)
        let migrator = LegacyDefaultsMigrator(reader: legacyReader, destination: settingsStorage,
            directory: locations.directory, home: directories.home, bundleDomain: bundleDomain)
        try await migrator.migrate(at: clock.now())
        let bookmarks = try await BookmarkStore(url: locations.bookmarks, home: directories.home)
        let stars = try await StarStore(url: locations.stars)
        let recents = try await RecentStore(url: locations.recent)
        let session = try await SessionStore(url: locations.session)
        let origins = try await TrashOriginStore(url: locations.trashOrigins)
        let tagCatalog = try await TagCatalogStore(url: locations.tagCatalog)
        let viewOptions = try await LocationViewOptionsStore(url: locations.viewOptions)
        return AppEnvironment(settings: SettingsStore(storage: settingsStorage), bookmarks: bookmarks,
            stars: stars, recents: recents, session: session, trashOrigins: origins,
            tagCatalog: tagCatalog, viewOptions: viewOptions,
            fileSystem: LiveFileSystem(volumeRoots: directories.volumeRoots), journal: OperationJournal(),
            clock: clock, directories: directories)
    }

    /// Fully in-memory stores and filesystem; no real defaults or filesystem writes (B-068).
    public static func test(home: URL = URL(fileURLWithPath: "/home/helm"),
                            clock: any HelmClock = SystemHelmClock()) async throws -> AppEnvironment {
        guard home.isFileURL else { throw AppConfigurationError.nonFileDirectory }
        let fileSystem = InMemoryFileSystem()
        // Seed each ancestor explicitly, matching the filesystem protocol's create semantics.
        var ancestors: [URL] = []
        var directory = home.standardizedFileURL
        while directory.path != "/" && !directory.path.isEmpty {
            ancestors.append(directory); directory.deleteLastPathComponent()
        }
        for url in ancestors.reversed() { try await fileSystem.createDirectory(at: url) }
        return AppEnvironment(settings: SettingsStore(storage: AppMemorySettings()),
            bookmarks: AppMemoryBookmarks(home: home), stars: AppMemoryStars(), recents: AppMemoryRecents(),
            session: AppMemorySession(), trashOrigins: AppMemoryTrashOrigins(),
            tagCatalog: AppMemoryTagCatalog(), viewOptions: AppMemoryViewOptions(), fileSystem: fileSystem,
            journal: OperationJournal(), clock: clock,
            directories: AppDirectories(home: home, applicationSupport: URL(fileURLWithPath: "/memory/helm")))
    }

    /// SettingsStore writes synchronously; the seven JSON documents require explicit flush (F-065/F-068).
    public func flushStores() async -> [AppFlushFailure] {
        let stores: [(String, any AppFlushable)] = [("bookmarks", bookmarks), ("stars", stars),
            ("recent", recents), ("session", session), ("trash-origins", trashOrigins),
            ("tag-catalog", tagCatalog), ("view-options", viewOptions)]
        var failures: [AppFlushFailure] = []
        for (name, store) in stores {
            do { try await store.flush() }
            catch { failures.append(AppFlushFailure(document: name, message: String(describing: error))) }
        }
        return failures
    }
}
