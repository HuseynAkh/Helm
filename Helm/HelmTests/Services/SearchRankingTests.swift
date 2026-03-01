import Foundation
import UniformTypeIdentifiers
import Testing
@testable import Helm

func registerSearchRankingTests() {
    TestRuntime.register("SpotlightSearchService ranks user document paths above system paths") {
        let userDoc = makeTestItem(
            path: "/Users/test/Documents/Project Plan.pdf",
            isDirectory: false,
            contentType: .pdf,
            modified: Date()
        )
        let systemDoc = makeTestItem(
            path: "/System/Library/CoreServices/Project Plan.pdf",
            isDirectory: false,
            contentType: .pdf,
            modified: Date()
        )

        let ranked = SpotlightSearchService.debugRank(
            items: [systemDoc, userDoc],
            queryText: "project plan",
            scope: .everywhere
        )

        try Check.equal(ranked.first?.url.path, userDoc.url.path, "User-facing folders should rank above system paths")
    }

    TestRuntime.register("SpotlightSearchService favors exact matches and recency in ranking") {
        let exactRecent = makeTestItem(
            path: "/Users/test/Desktop/Budget.xlsx",
            isDirectory: false,
            contentType: nil,
            modified: Date()
        )
        let partialOlder = makeTestItem(
            path: "/Users/test/Desktop/Annual Budget Draft.xlsx",
            isDirectory: false,
            contentType: nil,
            modified: Date(timeIntervalSinceNow: -60 * 60 * 24 * 20)
        )

        let ranked = SpotlightSearchService.debugRank(
            items: [partialOlder, exactRecent],
            queryText: "budget",
            scope: .everywhere
        )

        try Check.equal(ranked.first?.url.path, exactRecent.url.path, "Exact and recent match should rank highest")
    }
}

private func makeTestItem(
    path: String,
    isDirectory: Bool,
    contentType: UTType?,
    modified: Date
) -> FileItem {
    let url = URL(fileURLWithPath: path)
    return FileItem(
        id: url,
        url: url,
        name: url.lastPathComponent,
        isDirectory: isDirectory,
        isSymlink: false,
        isHidden: false,
        size: 0,
        modificationDate: modified,
        creationDate: modified,
        contentType: contentType,
        isPackage: false,
        isStarred: false
    )
}
