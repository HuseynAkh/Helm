#if os(macOS)
import XCTest
import HelmCore
@testable import HelmUI

/// Planned queries as Spotlight predicates: every word is a bound value, so quotes, wildcards, backslashes and
/// format signs never become predicate syntax, and the shape of the predicate is the query's.
final class AISearchPredicateTests: XCTestCase {
    /// Every comparison in a predicate, depth first.
    private func comparisons(_ predicate: NSPredicate) -> [NSComparisonPredicate] {
        if let compound = predicate as? NSCompoundPredicate {
            return (compound.subpredicates as? [NSPredicate] ?? []).flatMap(comparisons)
        }
        return (predicate as? NSComparisonPredicate).map { [$0] } ?? []
    }

    private func values(_ predicate: NSPredicate) -> [String] {
        comparisons(predicate).compactMap { $0.rightExpression.constantValue as? String }
    }

    private let hostile = ["in\"voice", "a*b?c", "back\\slash", "%@ OR 1==1", "' OR TRUEPREDICATE OR '", "x\") OR (\"y"]

    func testHostileWordsBecomeBoundValues() {
        for word in hostile {
            for query in [AISearchQuery(nameAll: [word]), AISearchQuery(nameAny: [word, "plain"]), AISearchQuery(contentAll: [word]),
                          AISearchQuery(extensions: [word])] {
                let predicate = AISearchPredicates.predicate(for: query)
                let parts = comparisons(predicate)
                XCTAssertFalse(parts.isEmpty, word)
                for part in parts {
                    XCTAssertEqual(part.leftExpression.expressionType, .keyPath, "the left side is always an attribute")
                    XCTAssertEqual(part.rightExpression.expressionType, .constantValue, "the right side is always a value")
                }
                for value in values(predicate) {
                    // The only wildcards are Helm's own, around or after the word; nothing the word held is left.
                    let inner = value.trimmingCharacters(in: CharacterSet(charactersIn: "*")).replacingOccurrences(of: "*.", with: "")
                    XCTAssertFalse(inner.contains("*") || inner.contains("?") || inner.contains("\\") || inner.contains("\"")
                                   || inner.contains("'"), "“\(value)” for “\(word)”")
                }
            }
        }
    }

    func testAWordsSyntaxNeverAddsAClause() {
        let predicate = AISearchPredicates.predicate(for: AISearchQuery(nameAll: ["%@ OR 1==1", "x\") OR (\"y"]))
        XCTAssertEqual(comparisons(predicate).count, 2, "one comparison a word, however the word reads")
        XCTAssertEqual(Set(values(predicate)), ["*%@ OR 1==1*", "*x) OR (y*"])
        // Written out and read back, it is still two comparisons of values.
        let again = NSPredicate(format: predicate.predicateFormat)
        XCTAssertEqual(comparisons(again).count, 2)
        XCTAssertEqual(Set(values(again)), Set(values(predicate)))
    }

    func testAWordOfNothingButSyntaxIsLeftOut() {
        let predicate = AISearchPredicates.predicate(for: AISearchQuery(nameAll: ["*?\\\""], nameAny: ["ok"]))
        XCTAssertEqual(values(predicate), ["*ok*"])
        XCTAssertEqual(AISearchPredicates.predicate(for: AISearchQuery(nameAll: ["**"])).predicateFormat,
                       NSPredicate(value: false).predicateFormat, "nothing left to ask, so nothing is found")
    }

    func testTheQueryShape() {
        let from = Date(timeIntervalSince1970: 1_772_000_000), to = Date(timeIntervalSince1970: 1_782_000_000)
        let query = AISearchQuery(nameAll: ["tax"], nameAny: ["invoice", "receipt"], contentAll: ["plumber"], folderAny: ["Receipts"],
                                  kinds: [.pdf, .image], extensions: ["pdf"], dateField: .modified, dateFrom: from, dateTo: to,
                                  sizeMinBytes: 10, sizeMaxBytes: 99)
        guard let and = AISearchPredicates.predicate(for: query) as? NSCompoundPredicate else { return XCTFail("fields are ANDed") }
        XCTAssertEqual(and.compoundPredicateType, .and)
        let parts = comparisons(and)
        let keys = parts.map(\.leftExpression.keyPath)
        XCTAssertFalse(keys.contains { $0.lowercased().contains("path") }, "folder words aren't asked of Spotlight")
        XCTAssertEqual(parts.filter { $0.leftExpression.keyPath == "kMDItemTextContent" }.compactMap { $0.rightExpression.constantValue as? String },
                       ["plumber*"])
        XCTAssertEqual(Set(parts.filter { $0.leftExpression.keyPath == "kMDItemContentTypeTree" }.compactMap { $0.rightExpression.constantValue as? String }),
                       ["com.adobe.pdf", "public.image"])
        let dates = parts.filter { $0.leftExpression.keyPath == NSMetadataItemFSContentChangeDateKey }
        XCTAssertEqual(dates.map(\.predicateOperatorType), [.greaterThanOrEqualTo, .lessThanOrEqualTo])
        XCTAssertEqual(dates.compactMap { $0.rightExpression.constantValue as? Date }, [from, to])
        let sizes = parts.filter { $0.leftExpression.keyPath == NSMetadataItemFSSizeKey }
        XCTAssertEqual(sizes.compactMap { ($0.rightExpression.constantValue as? NSNumber)?.int64Value }, [10, 99])
        XCTAssertTrue(values(and).contains("*tax*"))
        XCTAssertTrue(values(and).contains("*.pdf"))
        // The any-words are one OR among the ANDed fields.
        let ors = (and.subpredicates as? [NSPredicate] ?? []).compactMap { $0 as? NSCompoundPredicate }.filter { $0.compoundPredicateType == .or }
        XCTAssertTrue(ors.contains { Set(values($0)) == ["*invoice*", "*receipt*"] })
        // Names and words inside files ignore case and accents.
        for part in parts where part.predicateOperatorType == .like {
            XCTAssertTrue(part.options.contains(.caseInsensitive) && part.options.contains(.diacriticInsensitive))
        }
    }

    func testAnyDateLooksAtEveryDateSpotlightKeeps() {
        let from = Date(timeIntervalSince1970: 1_772_000_000)
        let predicate = AISearchPredicates.predicate(for: AISearchQuery(dateField: .any, dateFrom: from))
        guard let or = predicate as? NSCompoundPredicate, or.compoundPredicateType == .or else { return XCTFail("any date is an OR") }
        XCTAssertEqual(Set(comparisons(or).map(\.leftExpression.keyPath)),
                       [NSMetadataItemFSContentChangeDateKey, "kMDItemFSCreationDate", "kMDItemDateAdded", "kMDItemLastUsedDate"])
    }

    func testAnEmptyQueryFindsNothing() {
        XCTAssertEqual(AISearchPredicates.predicate(for: AISearchQuery()).predicateFormat, NSPredicate(value: false).predicateFormat)
    }
}
#endif
