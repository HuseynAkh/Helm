import XCTest
import HelmCore
@testable import HelmAgent

/// What the panel offers in the folder on show, Organize, worked out from two counts and the folder's place. Moving
/// and copying are asked for in the composer, so they're no suggestion of their own.
final class AgentSuggestionsTests: XCTestCase {
    private func make(items: Int, selected: Int = 0, storage: StorageFacts = .thisMac) -> [AgentSuggestion] {
        AgentSuggestions.make(itemCount: items, selectedCount: selected, storage: storage)
    }

    func testOrganizeAloneForAFolderWithItems() {
        let chips = make(items: 214)
        XCTAssertEqual(chips.map(\.kind), [.organize])
        XCTAssertEqual(chips.map(\.count), [214])
        XCTAssertEqual(chips.map(\.isSelection), [false])
        XCTAssertEqual(chips.map(\.title), ["Organize 214 items"])
        XCTAssertEqual(chips.map(\.id), ["organize"])
        XCTAssertEqual(make(items: 1).map(\.title), ["Organize 1 item"])
    }

    func testTheChipsFollowTheSelection() {
        let chips = make(items: 214, selected: 12)
        XCTAssertEqual(chips.map(\.kind), [.organize])
        XCTAssertEqual(chips.map(\.count), [12])
        XCTAssertEqual(chips.map(\.isSelection), [true])
        XCTAssertEqual(chips.map(\.title), ["Organize 12 selected"])
        XCTAssertEqual(make(items: 214, selected: 1).map(\.title), ["Organize 1 selected"])
        // The ids stay the same, so a chip keeps its place when the selection changes.
        XCTAssertEqual(chips.map(\.id), make(items: 214).map(\.id))
        // A count below zero is no selection.
        XCTAssertEqual(make(items: 3, selected: -1).map(\.isSelection), [false])
    }

    func testCountsAreTheRealOnes() {
        let grouped = 1_240.formatted(.number)
        XCTAssertEqual(make(items: 1_240).first?.title, "Organize \(grouped) items")
        XCTAssertEqual(make(items: 5_000, selected: 1_240).map(\.title), ["Organize \(grouped) selected"])
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
            XCTAssertEqual(make(items: 30, storage: place).count, 1, place.name)
        }
    }

    // MARK: What is sent

    func testTheSentencesAModelIsSentAreFixed() {
        let organize = AgentSuggestion(kind: .organize, count: 214, isSelection: false)
        XCTAssertEqual(AgentSuggestions.message(for: organize, depth: .thisFolder, root: "r1"),
                       "Organize the items in r1 into folders by kind. Depth: this folder. List them, then call propose_changes.")
        XCTAssertEqual(AgentSuggestions.message(for: organize, depth: .twoLevels, root: "r1"),
                       "Organize the items in r1 into folders by kind. Depth: 2 levels. List them, then call propose_changes.")
        XCTAssertEqual(AgentSuggestions.message(for: organize, depth: .allLevels, root: "r1"),
                       "Organize the items in r1 into folders by kind. Depth: all levels. List them, then call propose_changes.")
        XCTAssertEqual(AgentSuggestions.message(for: organize, depth: .thisFolder, root: "r27"),
                       "Organize the items in r27 into folders by kind. Depth: this folder. List them, then call propose_changes.")

        let selected = AgentSuggestion(kind: .organize, count: 12, isSelection: true)
        for depth in AgentOrganizeDepth.allCases {
            XCTAssertEqual(AgentSuggestions.message(for: selected, depth: depth, root: "r1"),
                           "Organize the 12 selected items in r1 into folders by kind. List them, then call propose_changes.")
        }
        XCTAssertEqual(AgentSuggestions.message(for: AgentSuggestion(kind: .organize, count: 1, isSelection: true), depth: .thisFolder, root: "r3"),
                       "Organize the 1 selected item in r3 into folders by kind. List them, then call propose_changes.")
        // A number in a sentence for a model is plain digits, whatever the Mac's region.
        XCTAssertEqual(AgentSuggestions.message(for: AgentSuggestion(kind: .organize, count: 1_240, isSelection: true), depth: .thisFolder, root: "r1"),
                       "Organize the 1240 selected items in r1 into folders by kind. List them, then call propose_changes.")
    }

    func testASentenceHoldsNoNameFromTheDisk() {
        // The sentence is made from the kind, the count and the alias alone: there is nowhere for a name to come in.
        // Apart from the alias, the only things that vary are digits.
        let fixedWords: Set<String> = ["Organize", "the", "items", "item", "selected", "in", "into", "folders", "by", "kind.",
                                       "Depth:", "this", "folder.", "levels.", "all",
                                       // What every sentence ends with: the answer is a plan.
                                       "List", "them,", "then", "call", "propose_changes."]
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

    func testDepthsAreTheDepthsAListingIsAskedFor() {
        XCTAssertEqual(AgentOrganizeDepth.thisFolder.rawValue, 1)
        XCTAssertEqual(AgentOrganizeDepth.twoLevels.rawValue, 2)
        XCTAssertEqual(AgentOrganizeDepth.allLevels.rawValue, 0)
        XCTAssertEqual(AgentOrganizeDepth.allCases, [.thisFolder, .twoLevels, .allLevels])
    }

    func testASuggestionIsAValue() {
        let chip = AgentSuggestion(kind: .organize, count: 3, isSelection: true)
        XCTAssertEqual(chip, AgentSuggestion(kind: .organize, count: 3, isSelection: true))
        XCTAssertNotEqual(chip, AgentSuggestion(kind: .organize, count: 4, isSelection: true))
        XCTAssertEqual(Set(make(items: 5)).count, 1)
        XCTAssertEqual(AgentSuggestion.Kind.organize.rawValue, "organize")
    }
}
