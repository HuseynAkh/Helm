import XCTest
import HelmCore

final class SettingsTests: XCTestCase {
    private struct Reader: SettingsReading {
        let values: [SettingKey: SettingValue]
        func value(for key: SettingKey) -> SettingValue? { values[key] }
    }
    func testAllDefaultsAndExactKeys() {
        let snapshot = SettingsSnapshot()
        XCTAssertEqual(snapshot.values.count, 36)
        XCTAssertEqual(SettingKey.allCases.count, 36)
        for key in SettingKey.allCases {
            XCTAssertEqual(key.rawValue, "helm.\(key)")
            XCTAssertEqual(snapshot[key], SettingsSchema.defaultValue(for: key))
        }
        XCTAssertEqual(snapshot.double(.gridIconSize), 96)
        XCTAssertFalse(snapshot.bool(.confirmBeforeTrash))
        XCTAssertTrue(snapshot.bool(.askOnConflict))
        XCTAssertTrue(snapshot.bool(.sidebarLiquidGlass))
        XCTAssertEqual(snapshot.double(.fileTextSize), 14)
        XCTAssertEqual(snapshot.double(.windowTransparency), 50)
        XCTAssertEqual(snapshot.string(.crossVolumeDragDefault), "copy")
        XCTAssertEqual(snapshot.defaultViewMode, .grid)
        XCTAssertEqual(snapshot.defaultSort, .defaultSort)
        XCTAssertFalse(snapshot.showHiddenFiles)
        // The welcome window opens by itself once, until it's been seen.
        XCTAssertFalse(snapshot.bool(.onboardingCompleted))
        XCTAssertEqual(SettingKey.onboardingCompleted.rawValue, "helm.onboardingCompleted")
        // Set Up leaves the rows for the copy it moved into Applications here, as row names and commas only.
        XCTAssertEqual(snapshot.string(.setupCarriedRows), "")
        XCTAssertEqual(SettingsSchema.validated(.string("viewer,access,move"), for: .setupCarriedRows), .string("viewer,access,move"))
        XCTAssertEqual(SettingsSchema.validated(.string("viewer; rm -rf"), for: .setupCarriedRows), .string(""))
        // Recent works out of the box; Settings › General can turn it off.
        XCTAssertTrue(snapshot.bool(.rememberRecentItems))
        XCTAssertEqual(SettingKey.rememberRecentItems.rawValue, "helm.rememberRecentItems")
        XCTAssertTrue(SettingsSchema.appliesLive(.rememberRecentItems))
        XCTAssertFalse(SettingsSchema.appliesLive(.defaultViewMode))
        XCTAssertTrue(SettingsSchema.appliesLive(.gridIconSize))
    }
    /// The AI panel opens 340 points wide until its edge is dragged, and a width read back stays within 300 to 560.
    func testThePanelWidthStartsAt340AndStaysWithinItsLimits() {
        XCTAssertEqual(SettingsSnapshot().double(.agentPanelWidth), 340)
        XCTAssertEqual(SettingKey.agentPanelWidth.rawValue, "helm.agentPanelWidth")
        XCTAssertEqual(SettingsSchema.validated(.double(420), for: .agentPanelWidth), .double(420))
        XCTAssertEqual(SettingsSchema.validated(.double(100), for: .agentPanelWidth), .double(300))
        XCTAssertEqual(SettingsSchema.validated(.double(2_000), for: .agentPanelWidth), .double(560))
        XCTAssertEqual(SettingsSchema.validated(.double(.nan), for: .agentPanelWidth), .double(340))
        XCTAssertEqual(SettingsSchema.validated(.string("wide"), for: .agentPanelWidth), .double(340))
        XCTAssertTrue(SettingsSchema.appliesLive(.agentPanelWidth))
    }
    /// No build has been through setup at first. A designated requirement is kept as it reads, and nothing else is.
    func testTheSetupBuildKeepsARequirementsTextOnly() {
        XCTAssertEqual(SettingsSnapshot().string(.setupBuild), "")
        XCTAssertEqual(SettingKey.setupBuild.rawValue, "helm.setupBuild")
        let adHoc = "cdhash H\"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c\""
        XCTAssertEqual(SettingsSchema.validated(.string(adHoc), for: .setupBuild), .string(adHoc))
        let signed = "identifier \"com.helm.filemanager\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\""
        XCTAssertEqual(SettingsSchema.validated(.string(signed), for: .setupBuild), .string(signed))
        XCTAssertEqual(SettingsSchema.validated(.string("two\nlines"), for: .setupBuild), .string(""))
        XCTAssertEqual(SettingsSchema.validated(.string(String(repeating: "a", count: 2_049)), for: .setupBuild), .string(""))
        XCTAssertEqual(SettingsSchema.validated(.bool(true), for: .setupBuild), .string(""))
    }
    /// No onboarding is under way at first. How far one got is kept as step names, commas and colons, and nothing else.
    func testTheSetupProgressKeepsStepNamesOnly() {
        XCTAssertEqual(SettingsSnapshot().string(.setupProgress), "")
        XCTAssertEqual(SettingKey.setupProgress.rawValue, "helm.setupProgress")
        let saved = "access:welcome,access,viewer,ai,done:asked,moved"
        XCTAssertEqual(SettingsSchema.validated(.string(saved), for: .setupProgress), .string(saved))
        XCTAssertEqual(SettingsSchema.validated(.string("access; rm -rf"), for: .setupProgress), .string(""))
        XCTAssertEqual(SettingsSchema.validated(.string("Access:welcome"), for: .setupProgress), .string(""))
        XCTAssertEqual(SettingsSchema.validated(.string(String(repeating: "a", count: 201)), for: .setupProgress), .string(""))
        XCTAssertEqual(SettingsSchema.validated(.bool(true), for: .setupProgress), .string(""))
        XCTAssertTrue(SettingsSchema.appliesLive(.setupProgress))
    }
    /// AI mode is off until the person turns it on, and its screen hasn't been shown. Both take effect at once.
    func testAIModeKeysAreOffAndApplyLive() {
        let snapshot = SettingsSnapshot()
        XCTAssertEqual(SettingKey.aiModeEnabled.rawValue, "helm.aiModeEnabled")
        XCTAssertEqual(SettingKey.aiIntroSeen.rawValue, "helm.aiIntroSeen")
        for key in [SettingKey.aiModeEnabled, .aiIntroSeen] {
            XCTAssertEqual(SettingsSchema.defaultValue(for: key), .bool(false), key.rawValue)
            XCTAssertFalse(snapshot.bool(key), key.rawValue)
            XCTAssertTrue(SettingsSchema.appliesLive(key), key.rawValue)
            XCTAssertEqual(SettingsSchema.validated(.bool(true), for: key), .bool(true), key.rawValue)
            // Only a true or false turns it on: a stored word or number reads as off.
            XCTAssertEqual(SettingsSchema.validated(.string("true"), for: key), .bool(false), key.rawValue)
            XCTAssertEqual(SettingsSchema.validated(.integer(1), for: key), .bool(false), key.rawValue)
        }
        let on = SettingsSnapshot(reader: Reader(values: [.aiModeEnabled: .bool(true)]))
        XCTAssertTrue(on.bool(.aiModeEnabled))
        XCTAssertFalse(on.bool(.aiIntroSeen))
    }
    func testValidationAndReader() throws {
        let snapshot = SettingsSnapshot(reader: Reader(values: [
            .gridIconSize: .double(64), .confirmBeforeTrash: .bool(true),
            .searchResultLimit: .integer(9000), .searchDebounceMilliseconds: .integer(-1),
            .maxCachedIcons: .integer(-1), .maxCachedThumbnails: .integer(-1),
            .completionDebounceMilliseconds: .integer(-1), .directoryCacheTTL: .double(.nan),
            .defaultViewMode: .string("column"), .defaultSortField: .string("dateModified"),
            .showHiddenFiles: .string("true")
        ]))
        XCTAssertEqual(snapshot.double(.gridIconSize), 64)
        XCTAssertTrue(snapshot.bool(.confirmBeforeTrash))
        XCTAssertEqual(snapshot.integer(.searchResultLimit), 800)
        XCTAssertEqual(snapshot.integer(.searchDebounceMilliseconds), 40)
        XCTAssertEqual(snapshot.integer(.maxCachedIcons), 100)
        XCTAssertEqual(snapshot.integer(.maxCachedThumbnails), 50)
        XCTAssertEqual(snapshot.integer(.completionDebounceMilliseconds), 30)
        XCTAssertEqual(snapshot.double(.directoryCacheTTL), 1.5)
        XCTAssertEqual(snapshot.defaultViewMode, .grid)
        XCTAssertEqual(snapshot.defaultSort.field, .dateModified)
        XCTAssertFalse(snapshot.showHiddenFiles)
        XCTAssertEqual(try JSONDecoder().decode(SettingsSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertEqual(SettingsSchema.validated(.double(-5), for: .gridIconSize), .double(48))
        XCTAssertEqual(SettingsSchema.validated(.double(500), for: .directoryCacheTTL), .double(5))
        XCTAssertEqual(SettingsSchema.validated(.string("bad"), for: .crossVolumeDragDefault), .string("copy"))
        XCTAssertEqual(snapshot.integer(.showHiddenFiles), 0)
        XCTAssertEqual(snapshot.double(.showHiddenFiles), 0)
        XCTAssertEqual(snapshot.string(.showHiddenFiles), "")
    }

    /// Open in Terminal starts with Terminal and keeps only a terminal Helm knows how to hand a folder to.
    func testTheTerminalAppIsAKnownOneOrTerminal() {
        XCTAssertEqual(SettingsSchema.defaultValue(for: .terminalApp), .string("com.apple.Terminal"))
        XCTAssertEqual(SettingsSchema.validated(.string("com.mitchellh.ghostty"), for: .terminalApp), .string("com.mitchellh.ghostty"))
        XCTAssertEqual(SettingsSchema.validated(.string("com.example.Shell; rm -rf"), for: .terminalApp), .string("com.apple.Terminal"))
        XCTAssertEqual(SettingsSchema.validated(.bool(true), for: .terminalApp), .string("com.apple.Terminal"))
        XCTAssertEqual(TerminalApps.name(of: "com.mitchellh.ghostty"), "Ghostty")
        XCTAssertEqual(Set(TerminalApps.known.map(\.id)).count, TerminalApps.known.count)
    }
}
