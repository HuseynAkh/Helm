// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

private struct AccessibilityFixedClock: HelmClock {
    let date: Date
    func now() -> Date { date }
}

final class AccessibilityTests: XCTestCase {
    private func formatting(_ locale: String = "en_US", now: TimeInterval = 1_700_000_000,
                            zone: String = "UTC") -> AccessibilityFormatting {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? calendar.timeZone
        return AccessibilityFormatting(locale: Locale(identifier: locale), calendar: calendar,
                                       clock: AccessibilityFixedClock(date: Date(timeIntervalSince1970: now)))
    }

    func testLocalizedNumbersAndBytes() {
        let cases: [(String, String, String)] = [
            ("en_US", "14.2 MB", "1,234"), ("fr_FR", "14,2 MB", "1\u{202f}234"),
            ("ar", "١٤٫٢ MB", "١٬٢٣٤")
        ]
        for (locale, size, count) in cases {
            XCTAssertEqual(formatting(locale).bytes(14_200_000), size, locale)
            XCTAssertEqual(formatting(locale).count(1234), count, locale)
            XCTAssertEqual(formatting(locale).count(-1), formatting(locale).count(0))
        }
    }

    func testByteBoundaries() {
        let f = formatting()
        for (bytes, expected): (Int64, String) in [(0, "0 bytes"), (1, "1 byte"), (999, "999 bytes"),
            (1000, "1 KB"), (999_999, "1 MB"), (Int64.max, "9.2 EB")] {
            XCTAssertEqual(f.bytes(bytes), expected)
        }
        XCTAssertNil(f.bytes(-1))
        XCTAssertNil(f.bytes(Int64.min))
        XCTAssertEqual(f.count(Int.max), "9,223,372,036,854,775,807")
    }

    func testRelativeDatesAndUnknownMetadata() {
        let f = formatting()
        let now = f.clock.now()
        XCTAssertEqual(f.modifiedDate(now, relative: true), "today")
        XCTAssertEqual(f.modifiedDate(now.addingTimeInterval(-86400), relative: true), "yesterday")
        XCTAssertEqual(f.modifiedDate(now.addingTimeInterval(86400), relative: true), "tomorrow")
        XCTAssertNil(f.modifiedDate(.distantPast, relative: false))
        XCTAssertNil(f.modifiedDate(Date(timeIntervalSince1970: .nan), relative: true))
        XCTAssertNil(f.modifiedDate(Date(timeIntervalSince1970: .infinity), relative: false))
        XCTAssertEqual(f.modifiedDate(now.addingTimeInterval(-172800), relative: true),
                       f.modifiedDate(now.addingTimeInterval(-172800), relative: false))
    }

    func testAbsoluteDatesUseInjectedLocaleAndTimezone() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var values: Set<String> = []
        for locale in ["en_US", "fr_FR", "ar"] {
            let value = try XCTUnwrap(formatting(locale).modifiedDate(date, relative: false))
            XCTAssertFalse(value.isEmpty)
            values.insert(value)
        }
        XCTAssertEqual(values.count, 3)
        XCTAssertNotEqual(formatting(zone: "UTC").modifiedDate(date, relative: false),
                          formatting(zone: "America/Toronto").modifiedDate(date, relative: false))
    }

    func testCalendarDayRelativeDatesAcrossDST() throws {
        // Noon after Toronto's spring-forward day: yesterday is only 23 hours earlier.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        XCTAssertEqual(now.timeIntervalSince(yesterday), 23 * 3600)
        let f = AccessibilityFormatting(locale: Locale(identifier: "en_US"), calendar: calendar,
                                       clock: AccessibilityFixedClock(date: now))
        XCTAssertEqual(f.modifiedDate(yesterday, relative: true), "yesterday")
    }

    func testRowVerbosityAndFullFilename() {
        let f = formatting()
        let name = "Very long اسم du fichier 👩🏽‍💻.txt"
        let entry = FileEntry(url: URL(fileURLWithPath: "/file"), name: name, size: 14_200_000,
                              modificationDate: f.clock.now(), cloudAvailability: .evicted)
        let tags = TagSet(tags: [FinderTag(name: "Work", colorIndex: 1)])
        XCTAssertEqual(RowDescription(verbosity: .brief).label(for: entry, selected: true, tags: tags, formatting: f),
                       name + ", file, selected")
        XCTAssertEqual(RowDescription().label(for: entry, selected: false, tags: tags, formatting: f),
                       name + ", file, 14.2 MB, Tags: Work, in cloud, not downloaded")
        XCTAssertEqual(RowDescription(verbosity: .detailed).label(for: entry, selected: true, tags: tags, formatting: f),
                       name + ", file, selected, 14.2 MB, Tags: Work, in cloud, not downloaded, modified today")
    }

    func testAllRowKindsAndDirectorySizes() {
        let kinds: [(FileEntryKind, String)] = [(.regular, "file"), (.directory, "folder"),
            (.package, "package"), (.symlinkToDirectory, "symbolic link to folder"),
            (.symlinkToFile, "symbolic link to file"), (.danglingSymlink, "broken symbolic link"),
            (.alias, "alias"), (.other, "item")]
        for (kind, text) in kinds {
            let entry = FileEntry(url: URL(fileURLWithPath: "/x"), kind: kind, size: 123)
            XCTAssertEqual(RowDescription(verbosity: .brief).label(for: entry, selected: false, formatting: formatting()),
                           "x, " + text)
            XCTAssertEqual(RowDescription().label(for: entry, selected: false, formatting: formatting()).contains("123 bytes"),
                           [FileEntryKind.regular, .symlinkToFile, .danglingSymlink, .alias, .other].contains(kind))
        }
    }

    func testPackageRawMetadataIsNotAnnouncedAsContentsSize() {
        // The bundle may contain 200 MB; 4096 is only its directory metadata.
        let package = FileEntry(url: URL(fileURLWithPath: "/App.app"), kind: .package, size: 4096)
        for verbosity: RowDescription.Verbosity in [.standard, .detailed] {
            XCTAssertEqual(RowDescription(verbosity: verbosity).label(for: package, selected: false,
                           formatting: formatting()), "App.app, package")
        }
        XCTAssertFalse(package.isDirectoryLike)
    }

    func testLocalizedKindAndEmptyFallback() {
        for kind in ["Document texte", " ", "\n"] {
            let entry = FileEntry(url: URL(fileURLWithPath: "/x"), localizedKindDescription: kind)
            XCTAssertEqual(RowDescription(verbosity: .brief).label(for: entry, selected: false, formatting: formatting("fr_FR")),
                           "x, " + (kind == "Document texte" ? kind : "file"))
        }
    }

    func testTagsAreNamedOrderedAndDeduplicated() {
        let tags = TagSet(tags: [FinderTag(name: "Red", colorIndex: 6), FinderTag(name: " ", colorIndex: 0),
                                FinderTag(name: "Red", colorIndex: 7), FinderTag(rawValue: "اسم\n99")])
        let entry = FileEntry(url: URL(fileURLWithPath: "/x"), size: -1)
        XCTAssertEqual(RowDescription(verbosity: .detailed).label(for: entry, selected: false, tags: tags, formatting: formatting()),
                       "x, file, Tags: Red, اسم")
    }

    func testCloudStatesAndAbsoluteRowDate() throws {
        for (state, suffix): (CloudAvailability, String) in [(.local, ", available offline"),
            (.evicted, ", in cloud, not downloaded"), (.downloading, ", downloading"), (.unknown, "")] {
            let entry = FileEntry(url: URL(fileURLWithPath: "/x"), size: -1, cloudAvailability: state)
            XCTAssertEqual(RowDescription().label(for: entry, selected: false, formatting: formatting()), "x, file" + suffix)
        }
        let f = formatting("fr_FR")
        let entry = FileEntry(url: URL(fileURLWithPath: "/x"), size: -1, modificationDate: f.clock.now())
        XCTAssertEqual(RowDescription(verbosity: .detailed, relativeDates: false).label(for: entry, selected: false, formatting: f),
                       "x, file, modified " + (try XCTUnwrap(f.modifiedDate(entry.modificationDate, relative: false))))
    }

    func testSelectionCountsAndInvalidSizes() {
        let f = formatting()
        XCTAssertEqual(SelectionAnnouncement.describe(selectedCount: 3, itemCount: 120, selectedBytes: 14_200_000, formatting: f),
                       "3 of 120 selected, 14.2 MB")
        XCTAssertEqual(SelectionAnnouncement.describe(selectedCount: 5, itemCount: 2, selectedBytes: -1, formatting: f), "2 of 2 selected")
        XCTAssertEqual(SelectionAnnouncement.describe(selectedCount: -1, itemCount: -1, selectedBytes: 0, formatting: f), "0 of 0 selected")
        XCTAssertEqual(SelectionAnnouncement.describe(selectedCount: 0, itemCount: 2, selectedBytes: 200, formatting: f), "0 of 2 selected")
        XCTAssertEqual(SelectionAnnouncement.describe(selectedCount: 1, itemCount: 2, selectedBytes: 0, formatting: f), "1 of 2 selected, 0 bytes")
        XCTAssertEqual(SelectionAnnouncement.describe(selectedCount: 3, itemCount: 120, formatting: formatting("ar")), "٣ of ١٢٠ selected")
    }

    func testNavigationStatesAndCounts() {
        let f = formatting()
        XCTAssertEqual(NavigationAnnouncement.describe(folderName: "Home", itemCount: 1, state: .loaded, formatting: f), "Entered Home, 1 item")
        XCTAssertEqual(NavigationAnnouncement.describe(folderName: "Home", itemCount: -1, state: .loading, formatting: f), "Entered Home, loading, 0 items so far")
        XCTAssertEqual(NavigationAnnouncement.describe(folderName: "Home", itemCount: 3, state: .partial, formatting: f), "Entered Home, 3 items, partial results")
        XCTAssertEqual(NavigationAnnouncement.describe(folderName: "اسم", itemCount: 2, state: .loaded, formatting: formatting("ar")), "Entered اسم, ٢ items")
    }

    func testOperationStartMilestonesAndThrottle() {
        var value = OperationAnnouncement(operationName: "Copy")
        XCTAssertEqual(value.announcement(for: .started, formatting: formatting(now: 100)), "Copy started")
        XCTAssertNil(value.announcement(for: .started, formatting: formatting(now: 100)))
        XCTAssertNil(value.announcement(for: .progress(0.09), formatting: formatting(now: 103)))
        XCTAssertNil(value.announcement(for: .progress(0.15), formatting: formatting(now: 101)))
        XCTAssertEqual(value.announcement(for: .progress(0.15), formatting: formatting(now: 102)), "Copy, 10 percent")
        XCTAssertNil(value.announcement(for: .progress(0.19), formatting: formatting(now: 110)))
        XCTAssertNil(value.announcement(for: .progress(0.01), formatting: formatting(now: 110)))
        XCTAssertEqual(value.announcement(for: .progress(0.45), formatting: formatting(now: 110)), "Copy, 40 percent")
        XCTAssertEqual(value.announcement(for: .completed, formatting: formatting(now: 110)), "Copy completed")
        XCTAssertNil(value.announcement(for: .completed, formatting: formatting(now: 111)))
        XCTAssertNil(value.announcement(for: .progress(1), formatting: formatting(now: 113)))
    }

    func testOperationInvalidProgressAndConfiguration() {
        var value = OperationAnnouncement(operationName: "Move", milestonePercent: 0, minimumInterval: .nan)
        XCTAssertEqual(value.milestonePercent, 1)
        XCTAssertEqual(value.minimumInterval, 2)
        for fraction: Double in [.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertNil(value.announcement(for: .progress(fraction), formatting: formatting()))
        }
        XCTAssertEqual(value.announcement(for: .progress(2), formatting: formatting()), "Move, 100 percent")
        XCTAssertNil(value.announcement(for: .started, formatting: formatting()))
        XCTAssertEqual(value.announcement(for: .failed(reason: "Disk full"), formatting: formatting()), "Move failed: Disk full")
        let capped = OperationAnnouncement(operationName: "x", milestonePercent: Int.max, minimumInterval: -1)
        XCTAssertEqual(capped.milestonePercent, 100)
        XCTAssertEqual(capped.minimumInterval, 0)
    }

    func testOperationFailureCancellationAndIndependentLifetimes() {
        var first = OperationAnnouncement(operationName: "Copy")
        var second = OperationAnnouncement(operationName: "Copy")
        XCTAssertEqual(first.announcement(for: .failed(reason: " \n"), formatting: formatting()), "Copy failed: Unknown error")
        XCTAssertNil(first.announcement(for: .cancelled, formatting: formatting()))
        XCTAssertEqual(second.announcement(for: .cancelled, formatting: formatting()), "Copy cancelled")
        XCTAssertNil(second.announcement(for: .started, formatting: formatting()))
    }

    func testOperationClockRewindAndIrregularMilestone() {
        var value = OperationAnnouncement(operationName: "Copy", milestonePercent: 30)
        XCTAssertEqual(value.announcement(for: .progress(0.3), formatting: formatting(now: 100)), "Copy, 30 percent")
        XCTAssertEqual(value.announcement(for: .progress(0.6), formatting: formatting(now: 90)), "Copy, 60 percent")
        XCTAssertEqual(value.announcement(for: .progress(1), formatting: formatting("ar", now: 92)), "Copy, ١٠٠ percent")
        XCTAssertEqual(value.announcement(for: .completed, formatting: formatting(now: 92)), "Copy completed")
    }

    func testIdentifiersAreStableScopedAndCollisionFree() {
        let id = ItemID(rawValue: "/a/../b")
        XCTAssertEqual(AccessibilityIdentifier.item(id), AccessibilityIdentifier.item(ItemID(rawValue: "/b")))
        XCTAssertEqual(AccessibilityIdentifier.item(id), "helm.a11y.v1.6d61696e.content.item.2f62")
        XCTAssertNotEqual(AccessibilityIdentifier.item(id), AccessibilityIdentifier.item(ItemID(rawValue: "/B")))
        XCTAssertNotEqual(AccessibilityIdentifier.item(id, scope: "tab1"), AccessibilityIdentifier.item(id, scope: "tab2"))
        XCTAssertNotEqual(AccessibilityIdentifier.item(id), AccessibilityIdentifier.item(id, in: .sidebar))
        XCTAssertNotEqual(AccessibilityIdentifier.item(id), AccessibilityIdentifier.control("/b", in: .content))
        let names: [String] = ["", ".", "/", "%2f", "é", "e\u{301}", "👩🏽‍💻", "اسم", "a.b", "a/b", "a\u{0}b"]
        XCTAssertEqual(Set(names.map { AccessibilityIdentifier.control($0, in: .toolbar) }).count, names.count)
        XCTAssertEqual(Set(AccessibilityIdentifier.Region.allCases.map { AccessibilityIdentifier.region($0) }).count,
                       AccessibilityIdentifier.Region.allCases.count)
        XCTAssertNotEqual(AccessibilityIdentifier.control("c", in: .toolbar, scope: "a.b"),
                          AccessibilityIdentifier.control("b.c", in: .toolbar, scope: "a"))
    }

    func testAllToolbarAndContextActionsHaveDescriptions() {
        XCTAssertEqual(Set(ToolbarCommand.allCases.map(ActionDescriptions.toolbar)).count, ToolbarCommand.allCases.count)
        XCTAssertEqual(ActionDescriptions.toolbar(.focusLocation), "Edit location")
        for context: CommandMenuContext in [.file, .folder, .background, .multiple, .trash, .recent] {
            for item in ContextMenuModel.menu(for: context).sections.flatMap({ $0 }) {
                XCTAssertEqual(ActionDescriptions.contextMenu(item), item.title)
                XCTAssertEqual(ActionDescriptions.contextMenu(item, targetName: "اسم", enabled: false), item.title + ", اسم, unavailable")
                XCTAssertEqual(ActionDescriptions.contextMenu(item, targetName: ""), item.title)
            }
        }
    }
}
