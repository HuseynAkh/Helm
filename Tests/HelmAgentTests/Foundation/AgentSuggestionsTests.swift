import XCTest
import HelmCore
@testable import HelmAgent

/// The three things the panel offers in the folder on show, worked out from two counts and the folder's place.
final class AgentSuggestionsTests: XCTestCase {
    private func make(items: Int, selected: Int = 0, storage: StorageFacts = .thisMac) -> [AgentSuggestion] {
        AgentSuggestions.make(itemCount: items, selectedCount: selected, storage: storage)
    }

    func testThreeChipsForAFolderWithItems() {
        let chips = make(items: 214)
        XCTAssertEqual(chips.map(\.kind), [.organize, .moveAll, .copyAll])
        XCTAssertEqual(chips.map(\.count), [214, 214, 214])
        XCTAssertEqual(chips.map(\.isSelection), [false, false, false])
        XCTAssertEqual(chips.map(\.title), ["Organize 214 items", "Move everything to…", "Copy everything to…"])
        XCTAssertEqual(chips.map(\.id), ["organize", "moveAll", "copyAll"])
        XCTAssertEqual(make(items: 1).map(\.title), ["Organize 1 item", "Move everything to…", "Copy everything to…"])
    }

    func testTheChipsFollowTheSelection() {
        let chips = make(items: 214, selected: 12)
        XCTAssertEqual(chips.map(\.kind), [.organize, .moveAll, .copyAll])
        XCTAssertEqual(chips.map(\.count), [12, 12, 12])
        XCTAssertEqual(chips.map(\.isSelection), [true, true, true])
        XCTAssertEqual(chips.map(\.title), ["Organize 12 selected", "Move 12 selected to…", "Copy 12 selected to…"])
        XCTAssertEqual(make(items: 214, selected: 1).map(\.title), ["Organize 1 selected", "Move 1 selected to…", "Copy 1 selected to…"])
        // The ids stay the same, so a chip keeps its place when the selection changes.
        XCTAssertEqual(chips.map(\.id), make(items: 214).map(\.id))
        // A count below zero is no selection.
        XCTAssertEqual(make(items: 3, selected: -1).map(\.isSelection), [false, false, false])
    }

    func testCountsAreTheRealOnes() {
        let grouped = 1_240.formatted(.number)
        XCTAssertEqual(make(items: 1_240).first?.title, "Organize \(grouped) items")
        XCTAssertEqual(make(items: 5_000, selected: 1_240).map(\.title),
                       ["Organize \(grouped) selected", "Move \(grouped) selected to…", "Copy \(grouped) selected to…"])
    }

    func testNoChipsForAnEmptyFolder() {
        XCTAssertEqual(make(items: 0), [])
        XCTAssertEqual(make(items: 0, selected: 0, storage: StorageFacts(kind: .cloud, name: "Google Drive", syncs: true)), [])
        XCTAssertEqual(make(items: -1), [])
    }

    func testNoChipsWhereNothingCanBeChanged() {
        XCTAssertEqual(make(items: 214, storage: StorageFacts(kind: .thisMac, name: "This Mac", isReadOnly: true)), [])
        XCTAssertEqual(make(items: 214, selected: 12, storage: StorageFacts(kind: .network, name: "Server", shared: .yes, isReadOnly: true)), [])
        XCTAssertEqual(make(items: 214, storage: StorageFacts(kind: .network, name: "Server", shared: .yes, isResponding: false)), [])
    }

    func testEveryKindOfPlaceThatCanBeChangedGetsChips() {
        let places = [
            StorageFacts.thisMac,
            StorageFacts(kind: .iCloud, name: "iCloud Drive", syncs: true),
            StorageFacts(kind: .cloud, name: "Google Drive", syncs: true, shared: .unknown),
            StorageFacts(kind: .network, name: "Server", shared: .yes, trash: .no),
            StorageFacts(kind: .external, name: "External disk", trash: .unknown)
        ]
        for place in places {
            XCTAssertEqual(make(items: 30, storage: place).count, 3, place.name)
        }
    }

    func testOnlyOrganizeRunsAtOnce() {
        XCTAssertEqual(make(items: 214).map(\.runsAtOnce), [true, false, false])
        XCTAssertEqual(make(items: 214, selected: 12).map(\.runsAtOnce), [true, false, false])
    }

    // MARK: What is sent and what is typed

    func testTheSentencesAModelIsSentAreFixed() {
        let organize = AgentSuggestion(kind: .organize, count: 214, isSelection: false)
        XCTAssertEqual(AgentSuggestions.message(for: organize, depth: .thisFolder, root: "r1"),
                       "Organize the items in r1 into folders by kind. Depth: this folder.")
        XCTAssertEqual(AgentSuggestions.message(for: organize, depth: .twoLevels, root: "r1"),
                       "Organize the items in r1 into folders by kind. Depth: 2 levels.")
        XCTAssertEqual(AgentSuggestions.message(for: organize, depth: .allLevels, root: "r1"),
                       "Organize the items in r1 into folders by kind. Depth: all levels.")
        XCTAssertEqual(AgentSuggestions.message(for: organize, depth: .thisFolder, root: "r27"),
                       "Organize the items in r27 into folders by kind. Depth: this folder.")

        let selected = AgentSuggestion(kind: .organize, count: 12, isSelection: true)
        for depth in AgentOrganizeDepth.allCases {
            XCTAssertEqual(AgentSuggestions.message(for: selected, depth: depth, root: "r1"),
                           "Organize the 12 selected items in r1 into folders by kind.")
        }
        XCTAssertEqual(AgentSuggestions.message(for: AgentSuggestion(kind: .organize, count: 1, isSelection: true), depth: .thisFolder, root: "r3"),
                       "Organize the 1 selected item in r3 into folders by kind.")
        // A number in a sentence for a model is plain digits, whatever the Mac's region.
        XCTAssertEqual(AgentSuggestions.message(for: AgentSuggestion(kind: .organize, count: 1_240, isSelection: true), depth: .thisFolder, root: "r1"),
                       "Organize the 1240 selected items in r1 into folders by kind.")
    }

    func testASentenceHoldsNoNameFromTheDisk() {
        // The sentence is made from the kind, the count and the alias alone: there is nowhere for a name to come in.
        // Apart from the alias, the only things that vary are digits.
        let fixedWords: Set<String> = ["Organize", "the", "items", "item", "selected", "in", "into", "folders", "by", "kind.",
                                       "Depth:", "this", "folder.", "levels.", "all"]
        for selection in [false, true] {
            for count in [1, 12, 5_000] {
                for depth in AgentOrganizeDepth.allCases {
                    let chip = AgentSuggestion(kind: .organize, count: count, isSelection: selection)
                    let sentence = AgentSuggestions.message(for: chip, depth: depth, root: "r1")
                    for word in sentence.split(separator: " ").map(String.init) where word != "r1" {
                        XCTAssertTrue(fixedWords.contains(word) || word.allSatisfy(\.isNumber), "\(word) in \(sentence)")
                    }
                    XCTAssertTrue(sentence.unicodeScalars.allSatisfy(\.isASCII), sentence)
                }
            }
        }
    }

    func testMoveAndCopyFillTheComposer() {
        let moveAll = AgentSuggestion(kind: .moveAll, count: 214, isSelection: false)
        let copyAll = AgentSuggestion(kind: .copyAll, count: 214, isSelection: false)
        let moveSelected = AgentSuggestion(kind: .moveAll, count: 12, isSelection: true)
        let copySelected = AgentSuggestion(kind: .copyAll, count: 12, isSelection: true)
        XCTAssertEqual(AgentSuggestions.composerText(for: moveAll), "Move everything in this folder to ")
        XCTAssertEqual(AgentSuggestions.composerText(for: copyAll), "Copy everything in this folder to ")
        XCTAssertEqual(AgentSuggestions.composerText(for: moveSelected), "Move the 12 selected items to ")
        XCTAssertEqual(AgentSuggestions.composerText(for: copySelected), "Copy the 12 selected items to ")
        XCTAssertEqual(AgentSuggestions.composerText(for: AgentSuggestion(kind: .moveAll, count: 1, isSelection: true)),
                       "Move the 1 selected item to ")
        // Organize runs by itself, so it types nothing.
        XCTAssertEqual(AgentSuggestions.composerText(for: AgentSuggestion(kind: .organize, count: 214, isSelection: false)), "")
        // What is typed is what is sent once the person has named a folder: with the folder, it reads as a message
        // that ends in a path.
        for chip in [moveAll, copyAll, moveSelected, copySelected] {
            let typed = AgentSuggestions.composerText(for: chip)
            XCTAssertEqual(AgentSuggestions.message(for: chip, depth: .thisFolder, root: "r1"), typed)
            guard case .message(_, let candidates) = AgentComposerIntent.parse(typed + "~/Pictures/2026") else {
                XCTFail("not a message: \(typed)")
                continue
            }
            XCTAssertEqual(candidates, [AgentTrailingPath(path: "~/Pictures/2026", prefix: typed)])
        }
    }

    func testDepthsAreTheDepthsAListingIsAskedFor() {
        XCTAssertEqual(AgentOrganizeDepth.thisFolder.rawValue, 1)
        XCTAssertEqual(AgentOrganizeDepth.twoLevels.rawValue, 2)
        XCTAssertEqual(AgentOrganizeDepth.allLevels.rawValue, 0)
        XCTAssertEqual(AgentOrganizeDepth.allCases, [.thisFolder, .twoLevels, .allLevels])
    }

    func testASuggestionIsAValue() {
        let chip = AgentSuggestion(kind: .moveAll, count: 3, isSelection: true)
        XCTAssertEqual(chip, AgentSuggestion(kind: .moveAll, count: 3, isSelection: true))
        XCTAssertNotEqual(chip, AgentSuggestion(kind: .moveAll, count: 4, isSelection: true))
        XCTAssertEqual(Set(make(items: 5)).count, 3)
        XCTAssertEqual(AgentSuggestion.Kind.organize.rawValue, "organize")
    }
}
