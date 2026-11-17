#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import HelmAgent
import HelmCore
@testable import HelmUI

/// Text from a model or the disk is drawn as plain text: a Markdown link in a reply or in a file's name stays the
/// characters it is, with no link to follow. The composer types plain text with every automatic change, detector,
/// Writing Tools and inline prediction off, and offers nothing to a service.
@MainActor final class AgentPlainTextTests: XCTestCase {
    private let hostile = "[Open me](https://example.test/x)"

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    // MARK: What the thread draws

    /// Every Text a view is built from, found by walking the view's value and the bodies of Helm's own views. Each
    /// is reported as plain (verbatim, with no attributes at all) or not, with its words when it is plain.
    private struct DrawnText {
        var plain: [String] = []
        var other = 0
    }

    private func drawn(_ view: Any) -> DrawnText {
        var found = DrawnText()
        walk(view, depth: 0, into: &found)
        return found
    }

    private func walk(_ value: Any, depth: Int, into found: inout DrawnText) {
        guard depth < 80 else { return }
        let mirror = Mirror(reflecting: value)
        // An optional is looked into, never taken for what it may hold.
        if mirror.displayStyle == .optional {
            if let held = mirror.children.first?.value { walk(held, depth: depth + 1, into: &found) }
            return
        }
        if value is Text {
            let storage = Mirror(reflecting: value).children.first { $0.label == "storage" }?.value
            let payload = storage.flatMap { Mirror(reflecting: $0).children.first }
            if payload?.label == "verbatim", let words = payload?.value as? String { found.plain.append(words) } else { found.other += 1 }
            return
        }
        // A model behind a view is not part of what it draws.
        if type(of: value) is AnyClass { return }
        if let view = value as? any View, String(reflecting: type(of: view)).hasPrefix("HelmUI."), let body = Self.body(of: view) {
            walk(body, depth: depth + 1, into: &found)
            return
        }
        for child in mirror.children { walk(child.value, depth: depth + 1, into: &found) }
    }

    private static func body<V: View>(of view: V) -> Any? { V.Body.self == Never.self ? nil : view.body }

    func testTheCheckSeesTextThatIsReadForLinks() {
        // A string handed to Text as a key is read as Markdown, and its link can be followed. The panel never does it.
        let control = drawn(VStack { Text(LocalizedStringKey(hostile)); Text(verbatim: hostile) })
        XCTAssertEqual(control.other, 1, "the key is seen for what it is")
        XCTAssertEqual(control.plain, [hostile])
    }

    func testAReplyWithAMarkdownLinkIsDrawnWithNoLink() {
        let model = AgentPanelModel()
        let line = AgentPanelModel.Line(id: 1, kind: .reply(AgentPanelModel.shownReply("See " + hostile)))
        let result = drawn(AgentThreadLineView(line: line, model: model))
        XCTAssertEqual(result.other, 0, "nothing in it is read for links")
        XCTAssertEqual(result.plain, ["See " + hostile], "the characters stay as they are")
    }

    func testAFileNameWithAMarkdownLinkIsDrawnWithNoLinkOnTheCard() {
        let root = AgentPlanItem(handle: "r1", rootAlias: "r1", path: "/home/helm/Downloads", name: "Downloads", kind: .directory,
                                 identity: nil, isDataless: false)
        let file = AgentPlanItem(handle: "f1", rootAlias: "r1", path: "/home/helm/Downloads/" + hostile, name: hostile,
                                 kind: .regular, identity: nil, isDataless: false)
        let plan = AgentChangePlan(title: .organize(rootLabel: hostile), steps: [.move(file, to: .existing(root))],
                                   groups: [AgentPlanGroup(id: 0, kind: .moves(toLabel: hostile, isNew: false), steps: [0])],
                                   notices: [.readOnly(place: hostile)], leftOut: [:])
        var card = AgentPlanCard(plan: plan, roots: [])
        card.toggleOpen(0)
        let group = try? XCTUnwrap(card.groupRows.first)
        let row = try? XCTUnwrap(group?.rows.first)
        XCTAssertEqual(row?.name, hostile)

        let whole = drawn(AgentPlanCardView(card: card, toggle: { _ in }, toggleOpen: { _ in }, apply: {}, cancel: {}))
        XCTAssertEqual(whole.other, 0)
        XCTAssertTrue(whole.plain.contains(AgentText.planTitleOrganize(hostile)), "\(whole.plain)")
        if let group {
            let drawnGroup = drawn(AgentPlanGroupView(group: group, isEnabled: true, toggle: {}, toggleOpen: {}))
            XCTAssertEqual(drawnGroup.other, 0)
            XCTAssertTrue(drawnGroup.plain.contains(AgentText.groupMoves(1, folder: hostile)), "\(drawnGroup.plain)")
        }
        if let row {
            let drawnRow = drawn(AgentPlanRowView(row: row))
            XCTAssertEqual(drawnRow.other, 0)
            XCTAssertTrue(drawnRow.plain.contains(hostile), "\(drawnRow.plain)")
        }
    }

    func testHelmsLinesAndTheFolderChipsDrawTheirWordsPlainly() {
        let line = drawn(AgentHelmLineView(words: AgentText.addAdded(hostile), button: AgentText.tryAgain, press: {}))
        XCTAssertEqual(line.other, 0)
        XCTAssertTrue(line.plain.contains(AgentText.addAdded(hostile)))
        XCTAssertTrue(line.plain.contains(AgentText.tryAgain), "a button's title is plain too")
        let chip = AgentPanelModel.Chip(id: "r2", label: hostile, kind: .cloud, symbol: "cloud", tooltip: hostile,
                                        placeLine: AgentText.chipInCloudFolder, marks: [], removable: true)
        let drawnChip = drawn(AgentFolderChipView(chip: chip, remove: {}))
        XCTAssertEqual(drawnChip.other, 0)
        XCTAssertTrue(drawnChip.plain.contains(hostile))
        let outcome = drawn(AgentOutcomeView(outcome: AgentPanelModel.Outcome(lines: [AgentText.trashFailed(hostile)], group: nil,
                                                                            changed: [], canUndo: false, undoLine: nil),
                                             undo: {}, show: {}))
        XCTAssertEqual(outcome.other, 0)
        XCTAssertTrue(outcome.plain.contains { $0.contains(AgentText.trashFailed(hostile)) })
    }

    // MARK: The composer

    func testTheComposerTypesPlainTextWithEveryAutomaticChangeOff() throws {
        let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 340, height: 120))
        let text = composer.textView
        XCTAssertFalse(text.isAutomaticSpellingCorrectionEnabled, "spelling correction")
        XCTAssertFalse(text.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(text.isGrammarCheckingEnabled)
        XCTAssertFalse(text.isAutomaticQuoteSubstitutionEnabled, "quote substitution")
        XCTAssertFalse(text.isAutomaticDashSubstitutionEnabled, "dash substitution")
        XCTAssertFalse(text.isAutomaticTextReplacementEnabled, "text substitution")
        XCTAssertFalse(text.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(text.isAutomaticLinkDetectionEnabled, "link detection")
        XCTAssertFalse(text.isAutomaticDataDetectionEnabled, "data detection")
        XCTAssertFalse(text.smartInsertDeleteEnabled)
        XCTAssertFalse(text.isRichText)
        XCTAssertFalse(text.importsGraphics)
        XCTAssertEqual(text.inlinePredictionType, .no, "inline prediction")
        if #available(macOS 15.0, *) { XCTAssertEqual(text.writingToolsBehavior, .none, "Writing Tools") }
        XCTAssertNil(text.validRequestor(forSendType: .string, returnType: nil), "no service gets the text")
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertNil(text.menu(for: click), "no menu to look a word up, share it or send it on")

        // What is typed stays exactly as typed.
        let typed = "\"quotes\" -- (c) https://example.test ~/Pictures/2026"
        text.insertText(typed, replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(text.string, typed)
        XCTAssertNil(text.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
        let linked = (0..<(text.string as NSString).length).contains { text.textStorage?.attribute(.link, at: $0, effectiveRange: nil) != nil }
        XCTAssertFalse(linked, "no part of it became a link")
    }

    /// The empty composer's hint reads on its field: light ink on the dark field and dark ink on the light one, over
    /// the window's material too, where AppKit hands the composer a vibrant appearance. That appearance's placeholder
    /// grey is an opaque mid grey made for blending, and drawn as the hint is it came out dark on the dark field.
    func testTheHintReadsOnTheFieldInLightAndDark() throws {
        for window in [NSAppearance.Name.darkAqua, .aqua] {
            for overMaterial in [true, false] {
                let ink = try hintInk(window: window, overMaterial: overMaterial)
                let label = "\(window.rawValue)\(overMaterial ? " over the material" : "")"
                if window == .darkAqua {
                    XCTAssertGreaterThan(ink.brightness, 0.8, "\(label): the hint is too dark to read on the field")
                } else {
                    XCTAssertLessThan(ink.brightness, 0.2, "\(label): the hint is too light to read on the field")
                }
                XCTAssertGreaterThan(ink.alpha, 0.3, "\(label): the hint is too faint")
                XCTAssertLessThan(ink.alpha, 0.9, "\(label): the hint is as strong as typed text")
            }
        }
    }

    /// The hint's ink as the empty composer draws it in a window of the given appearance, straight in the window or
    /// over a material as in the panel: how bright it is on average and how opaque at most, over the pixels it drew.
    private func hintInk(window appearance: NSAppearance.Name, overMaterial: Bool) throws -> (brightness: CGFloat, alpha: CGFloat) {
        let frame = NSRect(x: 0, y: 0, width: 340, height: 80)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: appearance)
        let composer = AgentComposerView(frame: frame)
        if overMaterial {
            let material = NSVisualEffectView(frame: frame)
            material.material = .sidebar
            material.addSubview(composer)
            window.contentView = material
        } else {
            window.contentView = composer
        }
        composer.layoutSubtreeIfNeeded()
        let text = composer.textView
        XCTAssertTrue(text.string.isEmpty)
        if overMaterial {
            let vibrant = text.effectiveAppearance.bestMatch(from: [.vibrantDark, .vibrantLight, .aqua, .darkAqua])
            XCTAssertTrue(vibrant == .vibrantDark || vibrant == .vibrantLight, "not drawn in a vibrant appearance")
        }
        let rep = try XCTUnwrap(text.bitmapImageRepForCachingDisplay(in: text.bounds))
        text.cacheDisplay(in: text.bounds, to: rep)
        var brightness: CGFloat = 0, alpha: CGFloat = 0, count: CGFloat = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.1 else { continue }
                brightness += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                alpha = max(alpha, color.alphaComponent)
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 20, "no hint was drawn")
        return (count > 0 ? brightness / count : 0, alpha)
    }
}
#endif
