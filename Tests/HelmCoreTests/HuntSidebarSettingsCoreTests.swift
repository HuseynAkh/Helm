import XCTest
@testable import HelmCore

/// Hunt: what Helm keeps by path follows a renamed or moved item, as Finder's sidebar follows a renamed folder.
final class HuntSidebarSettingsPathMoveTests: XCTestCase {
    /// Spelled out in full, so making the URLs doesn't ask the disk about paths that aren't there.
    private func move(_ from: String, _ to: String) -> PathMove {
        PathMove(from: URL(fileURLWithPath: from, isDirectory: false), to: URL(fileURLWithPath: to, isDirectory: false))
    }

    func testTheItemAndWhatsInsideItFollow() {
        let rename = PathMoves([move("/home/helm/Documents/Reports", "/home/helm/Documents/Reports 2026")])
        XCTAssertEqual(rename.relocated("/home/helm/Documents/Reports"), "/home/helm/Documents/Reports 2026")
        XCTAssertEqual(rename.relocated("/home/helm/Documents/Reports/2026/q2.txt"), "/home/helm/Documents/Reports 2026/2026/q2.txt")
        // A sibling that only shares the start of the name isn't inside it.
        XCTAssertNil(rename.relocated("/home/helm/Documents/Reports old"))
        XCTAssertNil(rename.relocated("/home/helm/Documents"))
    }

    func testMovesFollowInTheOrderTheyHappened() {
        // A rename that only changes case goes through a temporary name.
        let steps = [move("/home/helm/notes", "/home/helm/.helm-temp"), move("/home/helm/.helm-temp", "/home/helm/Notes"),
                     move("/home/helm/Notes", "/home/helm/Desktop/Notes")]
        XCTAssertEqual(PathMoves(steps).relocated("/home/helm/notes/a.txt"), "/home/helm/Desktop/Notes/a.txt")
    }

    func testPathsMatchHoweverTheyAreSpelled() {
        // The decomposed é from the disk matches the composed one in a saved path, and /private/tmp is /tmp.
        let decomposed = "/tmp/helm-hunt/Re\u{0301}sume\u{0301}s"
        let rename = PathMoves([move(decomposed, "/tmp/helm-hunt/CVs")])
        XCTAssertEqual(rename.relocated("/private/tmp/helm-hunt/Résumés/one.pdf"), "/tmp/helm-hunt/CVs/one.pdf")
        XCTAssertNil(PathMoves([move("/", "/elsewhere")]).relocated("/"))
    }

    func testRecordsKeepTheirPlacesAndOneWinsWhenTwoMeet() {
        let records = ["/a/One", "/a/Two", "/a/Three"]
        let moved = PathMoves([move("/a/Two", "/b/Two")]).relocate(records, path: { $0 }, rebuild: { $1 })
        XCTAssertEqual(moved, ["/a/One", "/b/Two", "/a/Three"])
        // Two moved onto Three's path, as a move with Replace does: Three's own record stays, Two's goes.
        let replaced = PathMoves([move("/a/Two", "/a/Three")]).relocate(records, path: { $0 }, rebuild: { $1 })
        XCTAssertEqual(replaced, ["/a/One", "/a/Three"])
        XCTAssertNil(PathMoves([move("/c", "/d")]).relocate(records, path: { $0 }, rebuild: { $1 }))
    }

    /// A batch moves thousands of items at once. The moves are read once, and only the items that moved are touched.
    func testABigBatchFollowsOnlyWhatMoved() {
        var moves = (0..<5_000).map { move("/home/helm/Downloads/file-\($0).txt", "/home/helm/Desktop/file-\($0).txt") }
        moves.insert(move("/home/helm/Documents/Reports", "/home/helm/Desktop/Reports"), at: 2_500)
        let records = (0..<200).map { "/home/helm/Documents/kept-\($0)" } + ["/home/helm/Documents/Reports/q1.txt"]
        let moved = PathMoves(moves).relocate(records, path: { $0 }, rebuild: { $1 })
        XCTAssertEqual(moved?.last, "/home/helm/Desktop/Reports/q1.txt")
        XCTAssertEqual(moved?.dropLast(), records.dropLast())
        XCTAssertTrue(PathMoves([move("/", "/x")]).isEmpty)
    }

    /// A hidden bookmark stays hidden, and a starred item keeps its place in your order, under its new path's ID.
    func testTheSidebarLayoutFollows() {
        let old = "/home/helm/Documents/Reports"
        let new = "/home/helm/Documents/Reports 2026"
        var layout = SidebarLayout()
        layout.setHidden(Place.id(.bookmark, path: old), true)
        layout.setHidden("downloads", true)
        layout.move(Place.id(.starred, path: old + "/q1.txt"), before: Place.id(.starred, path: "/home/helm/a.txt"), in: .starred,
                    natural: [Place.id(.starred, path: "/home/helm/a.txt"), Place.id(.starred, path: old + "/q1.txt")])
        let moved = layout.relocated(PathMoves([move(old, new)]))
        XCTAssertTrue(moved.isHidden(Place.id(.bookmark, path: new)))
        XCTAssertFalse(moved.isHidden(Place.id(.bookmark, path: old)))
        XCTAssertTrue(moved.isHidden("downloads"))
        XCTAssertEqual(moved.order(of: .starred), [Place.id(.starred, path: new + "/q1.txt"), Place.id(.starred, path: "/home/helm/a.txt")])
        // The Starred heading's own row isn't a path.
        XCTAssertEqual(SidebarLayout(hidden: ["starred-root"]).relocated(PathMoves([move("/home/helm/a", "/x")])).hidden, ["starred-root"])
    }
}

/// Hunt: turning "Update folders when they change" on or off gives the folder on show a new watch at once.
final class HuntSidebarSettingsMonitorTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/a")
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: root) }
    @discardableResult private func send(_ action: TabAction, _ state: inout TabState) -> [TabEffect] {
        let result = TabReducer.reduce(state, action, context: context)
        state = result.0
        return result.1
    }

    func testRestartingTheWatchReplacesItWithoutReadingTheFolder() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        let old = state.monitorGeneration
        // No read of its own: with updates off, a file made a moment later mustn't show up until a refresh.
        XCTAssertEqual(send(.restartMonitor, &state), [.cancel(.monitor, old), .startMonitor(state.location, state.monitorGeneration)])
        XCTAssertNotEqual(state.monitorGeneration, old)
        // The old watch's events no longer count; a new watch that starts catches up with the folder.
        XCTAssertTrue(send(.monitorEvent(old, .rescan), &state).isEmpty)
        XCTAssertEqual(send(.monitorWatching(state.monitorGeneration), &state), [.refreshPaths([], state.monitorGeneration)])
    }

    func testATabInTheBackgroundHasNoWatchToRestart() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        send(.deactivated, &state)
        let generation = state.monitorGeneration
        XCTAssertTrue(send(.restartMonitor, &state).isEmpty)
        XCTAssertEqual(state.monitorGeneration, generation)
    }
}
