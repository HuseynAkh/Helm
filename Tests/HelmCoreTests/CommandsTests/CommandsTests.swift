// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
@testable import HelmCore

final class CommandsTests: XCTestCase {
    private func items(_ menus: [MenuModel]) -> [CommandMenuItem] { menus.flatMap(\.sections).flatMap { $0 } }

    func testExactLegacyShortcutFixture() {
        // Independent fixture from main.swift:22–131 and audit section 2.7.
        let fixture: [(CommandID, String, KeyModifiers)] = [
            (.settings, ",", .command), (.hide, "h", .command), (.hideOthers, "h", [.command, .option]), (.quit, "q", .command),
            (.newWindow, "n", .command), (.newTab, "t", .command), (.newFolder, "N", [.command, .shift]),
            (.find, "f", .command), (.closeTab, "w", .command), (.undo, "z", .command), (.redo, "z", [.command, .shift]),
            (.cut, "x", .command), (.copy, "c", .command), (.paste, "v", .command), (.selectAll, "a", .command),
            (.rename, "\r", []), (.trash, "\u{8}", .command), (.properties, "i", .command),
            (.grid, "1", .command), (.list, "2", .command), (.sidebar, "s", [.command, .control]),
            (.hidden, ".", .command), (.refresh, "r", .command), (.back, "[", .command), (.forward, "]", .command),
            (.up, "\u{f700}", .command), (.home, "H", .command), (.location, "l", .command), (.star, "d", .command), (.minimize, "m", .command)
        ]
        XCTAssertEqual(items(MenuModel.legacy).compactMap(\.binding), fixture.map { KeyBinding(command: $0.0, key: $0.1, modifiers: $0.2) })
        XCTAssertFalse(items(MenuModel.legacy).contains { $0.isNew })
        XCTAssertEqual(MenuModel.legacy.map(\.title), ["Helm", "File", "Edit", "View", "Go", "Window", "Help"])
        XCTAssertEqual(MenuModel.legacy[1].sections.map { $0.map(\.title) }, [["New Window", "New Tab"], ["New Folder"], [], ["Find..."], ["Close Tab"]])
        XCTAssertTrue(MenuModel.legacy[6].sections.isEmpty)
    }

    func testAdditionsPreserveLegacyAndDoNotInstallReservedKeys() {
        for (old, new) in zip(MenuModel.legacy, MenuModel.menuBar) {
            XCTAssertEqual(items([new]).filter { !$0.isNew }, items([old]))
        }
        XCTAssertFalse(MenuModel.defaultBindings.contains { $0.command.isPlanned })
        XCTAssertEqual(MenuModel.defaultBindings.filter { $0.command == .open }.map(\.key), ["o", "\u{f701}"])
        XCTAssertEqual(MenuModel.defaultBindings.filter { $0.command == .quickLook }.map(\.key), [" "])
        XCTAssertFalse(MenuModel.defaultBindings.contains { $0.command == .duplicate })
        for item in items(MenuModel.menuBar) { XCTAssertEqual(item.validationRuleID, CommandValidation.rule(for: item.command)) }
    }

    func testDisplayAndUppercaseNormalization() {
        let fixture: [(String, KeyModifiers, String)] = [
            ("N", [.command, .shift], "⇧⌘N"), ("H", .command, "⇧⌘H"),
            ("h", [.option, .command], "⌥⌘H"), ("s", [.control, .command], "⌃⌘S"),
            ("\r", [], "↩"), ("\u{8}", .command, "⌘⌫"), (" ", [], "Space"),
            ("\u{f700}", .command, "⌘↑"), ("\u{f701}", .command, "⌘↓"),
            ("\u{f702}", [], "←"), ("\u{f703}", [], "→"), ("\t", [], "⇥"),
            ("\u{1b}", [], "⎋"), ("", .command, ""), ("é", [], "É")]
        for (key, flags, display) in fixture {
            XCTAssertEqual(KeyBinding(command: .open, key: key, modifiers: flags).displayString, display)
        }
        XCTAssertEqual(KeyModifiers.command.union(.shift).rawValue, 3)
    }

    func testValidationMatrixAndDefaultConflicts() {
        for location in [LocationKind.directory, .recent, .trash] {
            for count in [0, 1, 3] {
                for text in [false, true] {
                    for search in [false, true] {
                        for clipboard in [CommandClipboardState.empty, .text, .files, .cutFiles] {
                            let context = CommandContext(selectionCount: count, hasMutationTarget: true,
                                locationKind: location, clipboard: clipboard, textFieldFocused: text,
                                searchOverlayActive: search, canUndo: true, canRedo: true,
                                canGoBack: true, canGoForward: true, canGoUp: true)
                            XCTAssertTrue(BindingConflictDetector.conflicts(in: MenuModel.defaultBindings, context: context).isEmpty)
                            let mutation = count > 0 && !text && !search && location == .directory
                            for command in [CommandID.rename, .trash, .duplicate] {
                                XCTAssertEqual(CommandValidation.state(for: command, in: context), mutation ? .enabled : .disabled, command.rawValue)
                            }
                            XCTAssertEqual(CommandValidation.state(for: .open, in: context), count > 0 && !text ? .enabled : .disabled)
                            let paste = text || (location == .directory && !search && (clipboard == .files || clipboard == .cutFiles))
                            XCTAssertEqual(CommandValidation.state(for: .paste, in: context), paste ? .enabled : .disabled)
                            for command in CommandID.allCases where command.isPlanned {
                                XCTAssertEqual(CommandValidation.state(for: command, in: context), .disabled)
                            }
                        }
                    }
                }
            }
        }
    }

    func testFocusTypeSelectHistoryUndoAndVirtualCommands() {
        var context = CommandContext(selectionCount: 2, hasMutationTarget: true)
        XCTAssertEqual(CommandValidation.state(for: .rename, in: context), .enabled) // F-055 multi-return
        XCTAssertEqual(CommandValidation.state(for: .properties, in: context), .disabled)
        XCTAssertEqual(CommandValidation.state(for: .quickLook, in: context), .enabled)
        context.typeSelectActive = true
        XCTAssertEqual(CommandValidation.state(for: .quickLook, in: context), .disabled)
        context.paneFocused = false
        XCTAssertEqual(CommandValidation.state(for: .rename, in: context), .disabled)
        XCTAssertEqual(CommandValidation.state(for: .selectAll, in: context), .disabled)
        for command in [CommandID.undo, .redo, .back, .forward, .up] {
            XCTAssertEqual(CommandValidation.state(for: command, in: context), .disabled)
        }
        context.textFieldFocused = true
        for command in [CommandID.cut, .copy, .paste, .selectAll, .undo, .redo] {
            XCTAssertEqual(CommandValidation.state(for: command, in: context), .enabled)
        }
        for command in [CommandID.rename, .trash, .permanentDelete, .star, .duplicate, .open, .quickLook] {
            XCTAssertEqual(CommandValidation.state(for: command, in: context), .disabled)
        }
        context.textFieldFocused = false
        XCTAssertEqual(CommandValidation.state(for: .putBack, in: context), .hidden)
        XCTAssertEqual(CommandValidation.state(for: .emptyTrash, in: context), .hidden)
        XCTAssertEqual(CommandValidation.state(for: .clearRecent, in: context), .hidden)
        context.locationKind = .trash
        for command in [CommandID.putBack, .emptyTrash, .permanentDelete] {
            XCTAssertEqual(CommandValidation.state(for: command, in: context), .enabled)
        }
        context.locationKind = .recent
        XCTAssertEqual(CommandValidation.state(for: .clearRecent, in: context), .enabled)
        context.hasWindow = false
        for command in CommandID.allCases where CommandValidation.rule(for: command) != .application {
            XCTAssertEqual(CommandValidation.state(for: command, in: context), .disabled)
        }
        XCTAssertEqual(CommandContext(selectionCount: -5).selectionCount, 0)
    }

    func testEveryCommandHasConservativeDefaultAndRuleCoverage() {
        let defaults = CommandContext()
        let enabled: Set<CommandID> = [.about, .settings, .advancedOptions, .services, .hide,
            .hideOthers, .showAll, .quit, .newWindow, .bringAllToFront, .help,
            .newTab, .find, .closeTab, .grid, .list, .sidebar, .hidden, .refresh,
            .home, .minimize, .zoom, .selectAll, .location, .eject, .closeWindow, .reopenClosedTab,
            .nextTab, .previousTab, .desktop, .documents, .downloads, .recents, .applications, .utilities, .connectToServer]
        let hidden: Set<CommandID> = [.putBack, .emptyTrash, .clearRecent]
        for command in CommandID.allCases {
            let expected: CommandAvailability = enabled.contains(command) ? .enabled : hidden.contains(command) ? .hidden : .disabled
            XCTAssertEqual(CommandValidation.state(for: command, in: defaults), expected, command.rawValue)
        }
        var context = CommandContext(selectionCount: 1, hasMutationTarget: true,
            clipboard: .files, canUndo: true, canRedo: true, canGoBack: true,
            canGoForward: true, canGoUp: true)
        for command in [CommandID.newFolder, .newFile, .newTextFile, .newFromTemplate,
                        .directoryProperties, .copyPath, .removeBookmark, .properties,
                        .openWith, .undo, .redo, .back, .forward, .up, .share, .star] {
            XCTAssertEqual(CommandValidation.state(for: command, in: context), .enabled, command.rawValue)
        }
        context.hasMutationTarget = false
        for command in [CommandID.newFolder, .newFile, .newTextFile, .newFromTemplate,
                        .directoryProperties, .copyPath, .removeBookmark, .paste, .cut] {
            XCTAssertEqual(CommandValidation.state(for: command, in: context), .disabled, command.rawValue)
        }
        XCTAssertEqual(CommandValidation.state(for: .copy, in: context), .enabled)
        context.locationKind = .trash
        context.selectionCount = 0
        XCTAssertEqual(CommandValidation.state(for: .putBack, in: context), .disabled)
        XCTAssertEqual(CommandValidation.state(for: .permanentDelete, in: context), .disabled)
    }

    func testConflictDetectionFiltersInactiveAndNormalizesShift() {
        let first = KeyBinding(command: .home, key: "H")
        let second = KeyBinding(command: .newWindow, key: "h", modifiers: [.command, .shift])
        let conflict = BindingConflict(first: first, second: second)
        XCTAssertEqual(BindingConflictDetector.conflicts(in: [first, second], context: CommandContext()), [conflict])
        XCTAssertTrue(BindingConflictDetector.conflicts(in: [first, first], context: CommandContext()).isEmpty)
        XCTAssertTrue(BindingConflictDetector.conflicts(in: [first, second], context: CommandContext(hasWindow: false)).isEmpty)
        let empty = KeyBinding(command: .quit, key: "")
        XCTAssertTrue(BindingConflictDetector.conflicts(in: [empty, empty], context: CommandContext()).isEmpty)
        XCTAssertTrue(BindingConflictDetector.conflicts(in: [first, KeyBinding(command: .hide, key: "h")], context: CommandContext()).isEmpty)
    }

    func testContextMenuExactBaselineAndAdditions() {
        let single: [[CommandID]] = [[.open, .openWith], [.cut, .copy, .paste], [.star], [.rename, .trash], [.properties, .share]]
        for kind in [CommandMenuContext.file, .folder, .recent, .trash] {
            let menu = ContextMenuModel.menu(for: kind, includeAdditions: false)
            XCTAssertEqual(menu.sections.map { $0.map(\.command) }, single)
        }
        let multi = ContextMenuModel.menu(for: .multiple, selectionCount: 3, includeAdditions: false)
        XCTAssertEqual(multi.sections.map { $0.map(\.command) }, [[.open], [.cut, .copy, .paste], [.rename, .trash], [.share]])
        XCTAssertEqual(items([multi]).map(\.title), ["Open 3 Items", "Cut", "Copy", "Paste", "Rename 3 Items...", "Move to Trash", "Share"])
        XCTAssertNil(items([multi]).first { $0.command == .rename }?.binding)
        let background = ContextMenuModel.menu(for: .background, includeAdditions: false)
        XCTAssertEqual(background.sections.map { $0.map(\.command) }, [[.paste], [.newFolder, .newFile], [.directoryProperties]])
        XCTAssertEqual(ContextMenuModel.menu(for: .file, selectionCount: -1, includeAdditions: false), background)
        XCTAssertEqual(items([ContextMenuModel.menu(for: .file, isStarred: true)]).first { $0.command == .star }?.title, "Remove from Starred")
        for kind in [CommandMenuContext.file, .folder, .multiple, .background, .trash, .recent] {
            let base = ContextMenuModel.menu(for: kind, selectionCount: 2, includeAdditions: false)
            let added = ContextMenuModel.menu(for: kind, selectionCount: 2)
            XCTAssertEqual(items([added]).filter { !$0.isNew }, items([base]))
        }
        XCTAssertTrue(items([ContextMenuModel.menu(for: .trash)]).contains { $0.command == .putBack && $0.isNew })
        XCTAssertTrue(items([ContextMenuModel.menu(for: .recent)]).contains { $0.command == .clearRecent && $0.isNew })
        XCTAssertEqual(ContextMenuModel.newFileFallback.command, .newTextFile)
    }
}
