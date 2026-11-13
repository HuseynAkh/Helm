import XCTest
@testable import HelmAgent

/// JSON as it is taken from a provider and handed back: nothing nested too deep, every kind of value kept apart,
/// and the same value always written as the same bytes.
final class AgentJSONTests: XCTestCase {
    private func json(_ text: String) throws -> AgentJSON { try AgentJSON(data: Data(text.utf8)) }
    private func text(_ json: AgentJSON, sortedKeys: Bool = true) -> String {
        String(decoding: json.data(sortedKeys: sortedKeys), as: UTF8.self)
    }
    private func nested(_ open: String, _ close: String, levels: Int, inside: String = "") -> String {
        String(repeating: open, count: levels) + inside + String(repeating: close, count: levels)
    }

    // MARK: Depth

    func testThirtyTwoLevelsAreTakenAndThirtyThreeRefused() throws {
        XCTAssertEqual(AgentJSON.maxDepth, 32)
        XCTAssertNoThrow(try json(nested("[", "]", levels: 32)))
        XCTAssertThrowsError(try json(nested("[", "]", levels: 33))) { XCTAssertEqual($0 as? AgentJSONError, .tooDeep) }

        XCTAssertNoThrow(try json(nested(#"{"a":"#, "}", levels: 32, inside: "1")))
        XCTAssertThrowsError(try json(nested(#"{"a":"#, "}", levels: 33, inside: "1"))) { XCTAssertEqual($0 as? AgentJSONError, .tooDeep) }

        // Arrays and objects count together.
        let mixed = String(repeating: #"[{"a":"#, count: 16) + "0" + String(repeating: "}]", count: 16)
        XCTAssertNoThrow(try json(mixed))
        XCTAssertThrowsError(try json("[" + mixed + "]")) { XCTAssertEqual($0 as? AgentJSONError, .tooDeep) }
        XCTAssertThrowsError(try json(nested("[", "]", levels: 10_000))) { XCTAssertEqual($0 as? AgentJSONError, .tooDeep) }
    }

    func testDepthIsFoundBeforeAnythingIsDecoded() {
        // Never closed, so it isn't JSON at all: the depth is what is reported, since it is looked at first.
        let open = Data(String(repeating: "[", count: 200).utf8)
        XCTAssertThrowsError(try AgentJSON(data: open)) { XCTAssertEqual($0 as? AgentJSONError, .tooDeep) }
        XCTAssertThrowsError(try AgentJSON.checkDepth(of: open)) { XCTAssertEqual($0 as? AgentJSONError, .tooDeep) }
        XCTAssertNoThrow(try AgentJSON.checkDepth(of: Data(String(repeating: "[", count: 32).utf8)))
    }

    func testBracketsInsideAStringDoNotCount() throws {
        let brackets = String(repeating: "[{", count: 100)
        XCTAssertEqual(try json("[\"\(brackets)\"]"), .array([.string(brackets)]))
        // A quote written as an escape doesn't end the string, and a backslash written as one doesn't hide the quote after it.
        let forty = String(repeating: "[", count: 40)
        XCTAssertEqual(try json(#"["\""# + forty + #"\""]"#), .array([.string("\"" + forty + "\"")]))
        XCTAssertEqual(try json(#"["\\", [[1]]]"#), .array([.string("\\"), .array([.array([.number(1)])])]))
        let deepAfterBackslash = #"["\\","# + nested("[", "]", levels: 32) + "]"
        XCTAssertThrowsError(try json(deepAfterBackslash)) { XCTAssertEqual($0 as? AgentJSONError, .tooDeep) }
    }

    func testClosingBracketsDoNotBuyDepth() {
        // Brackets that close nothing must not let deeper nesting through afterwards.
        let text = String(repeating: "]", count: 40) + nested("[", "]", levels: 60)
        XCTAssertThrowsError(try json(text))
        XCTAssertThrowsError(try AgentJSON.checkDepth(of: Data(text.utf8)))
    }

    // MARK: Values

    func testEveryKindOfValue() throws {
        XCTAssertEqual(try json("null"), .null)
        XCTAssertEqual(try json("true"), .bool(true))
        XCTAssertEqual(try json("false"), .bool(false))
        XCTAssertEqual(try json("42"), .number(42))
        XCTAssertEqual(try json("-0.5"), .number(-0.5))
        XCTAssertEqual(try json("1e3"), .number(1000))
        XCTAssertEqual(try json(#""words""#), .string("words"))
        XCTAssertEqual(try json("[]"), .array([]))
        XCTAssertEqual(try json("{}"), .object([:]))
        XCTAssertEqual(try json(#" {"a": [1, "two", null, true, {"b": []}]} "#),
                       .object(["a": .array([.number(1), .string("two"), .null, .bool(true), .object(["b": .array([])])])]))
    }

    func testTrueAndFalseAreNotOneAndZero() throws {
        XCTAssertEqual(try json("[true, 1, false, 0]"), .array([.bool(true), .number(1), .bool(false), .number(0)]))
        XCTAssertNotEqual(try json("true"), try json("1"))
        XCTAssertNotEqual(try json("false"), try json("0"))
        XCTAssertNotEqual(try json(#""1""#), try json("1"))
        XCTAssertNotEqual(try json("null"), try json("0"))
    }

    func testStringsKeepTheirCharacters() throws {
        XCTAssertEqual(try json(#""a\"b\\c\/d\n\té🙂""#), .string("a\"b\\c/d\n\té🙂"))
        XCTAssertEqual(try json("\"Übersicht – 写真 🙂\""), .string("Übersicht – 写真 🙂"))
    }

    func testBytesThatAreNotJSONAreMalformed() {
        for text in ["", " ", "{", "[1,", "nope", "{'a': 1}", "[1 2]", "]", "{\"a\"}", "\"open", "tru", "+1", "01"] {
            XCTAssertThrowsError(try json(text), text) { XCTAssertEqual($0 as? AgentJSONError, .malformed, text) }
        }
        XCTAssertThrowsError(try AgentJSON(data: Data([0xFF, 0xFE, 0x00]))) { XCTAssertEqual($0 as? AgentJSONError, .malformed) }
    }

    // MARK: Bytes out

    func testKeysAreWrittenInAFixedOrder() throws {
        let value = AgentJSON.object(["b": .number(2), "a": .number(1), "C": .number(3), "aa": .null, "é": .bool(true), "10": .string("x")])
        XCTAssertEqual(text(value), #"{"10":"x","C":3,"a":1,"aa":null,"b":2,"é":true}"#)
        // The same value gives the same bytes every time.
        XCTAssertEqual(Set((0..<20).map { _ in value.data() }).count, 1)
        // Without sorting the bytes are still the same value.
        XCTAssertEqual(try AgentJSON(data: value.data(sortedKeys: false)), value)
    }

    func testNumbersAreWrittenAsShortAsTheyAre() {
        XCTAssertEqual(text(.array([.number(1), .number(0), .number(-3), .number(1000000), .number(0.5), .number(-2.25)])),
                       "[1,0,-3,1000000,0.5,-2.25]")
        XCTAssertEqual(text(.number(9_007_199_254_740_992)), "9007199254740992")
        XCTAssertEqual(text(.number(1e300)), "1e+300")
        // JSON has no word for these.
        XCTAssertEqual(text(.array([.number(.infinity), .number(-.infinity), .number(.nan)])), "[null,null,null]")
    }

    func testStringsAreWrittenWithOnlyTheEscapesJSONNeeds() {
        XCTAssertEqual(text(.string("a\"b\\c/d")), #""a\"b\\c/d""#)
        XCTAssertEqual(text(.string("line\nbreak\ttab\rreturn")), #""line\nbreak\ttab\rreturn""#)
        XCTAssertEqual(text(.string("\u{0}\u{1F}\u{7F}")), "\"\\u0000\\u001f\u{7F}\"")
        XCTAssertEqual(text(.string("é 写真 🙂 \u{2028}")), "\"é 写真 🙂 \u{2028}\"")
        // A path keeps its slashes, so it can be looked for in what was sent.
        XCTAssertEqual(text(.object(["path": .string("/home/helm/Documents")])), #"{"path":"/home/helm/Documents"}"#)
    }

    func testWhatIsWrittenIsTakenBackUnchanged() throws {
        let value = AgentJSON.object([
            "null": .null, "yes": .bool(true), "no": .bool(false), "whole": .number(12), "part": .number(0.125),
            "text": .string("quote \" slash / back \\ break \n tab \t null \u{0} é 🙂"),
            "list": .array([.number(1), .array([]), .object([:]), .string("")]),
            "nested": .object(["deeper": .object(["deepest": .array([.null])])])
        ])
        XCTAssertEqual(try AgentJSON(data: value.data()), value)
        XCTAssertEqual(try AgentJSON(data: value.data(sortedKeys: false)), value)
        // Foundation reads the same bytes as the same JSON.
        let foundation = try JSONSerialization.jsonObject(with: value.data()) as? [String: Any]
        XCTAssertEqual(foundation?["text"] as? String, "quote \" slash / back \\ break \n tab \t null \u{0} é 🙂")
        XCTAssertEqual(foundation?["whole"] as? Int, 12)
    }

    // MARK: Codable and Hashable

    private struct Envelope: Codable, Equatable {
        var args: AgentJSON
        var maybe: AgentJSON?
    }

    func testAValueTravelsInsideACodableType() throws {
        let decoded = try JSONDecoder().decode(Envelope.self, from: Data(#"{"args": {"folder": "r1", "depth": 1, "all": true, "none": null, "list": [1.5, "x"]}}"#.utf8))
        XCTAssertEqual(decoded.args, .object(["folder": .string("r1"), "depth": .number(1), "all": .bool(true), "none": .null,
                                              "list": .array([.number(1.5), .string("x")])]))
        XCTAssertNil(decoded.maybe)
        let again = try JSONDecoder().decode(Envelope.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(again, decoded)
        // The decoder keeps true apart from 1, as reading the bytes directly does.
        let flags = try JSONDecoder().decode(Envelope.self, from: Data(#"{"args": [true, 1, false, 0, "1"]}"#.utf8))
        XCTAssertEqual(flags.args, .array([.bool(true), .number(1), .bool(false), .number(0), .string("1")]))
    }

    func testValuesAreHashable() {
        let one = AgentJSON.object(["a": .array([.number(1), .string("x")])])
        let same = AgentJSON.object(["a": .array([.number(1), .string("x")])])
        let other = AgentJSON.object(["a": .array([.number(1), .string("y")])])
        XCTAssertEqual(Set([one, same, other]).count, 2)
        XCTAssertEqual(one.hashValue, same.hashValue)
    }

    func testLookingInsideAValue() throws {
        let value = try json(#"{"name": "a.png", "items": [1, 2], "on": true, "size": 12.5, "inner": {"k": null}}"#)
        XCTAssertEqual(value["name"]?.stringValue, "a.png")
        XCTAssertEqual(value["items"]?.arrayValue, [.number(1), .number(2)])
        XCTAssertEqual(value["on"]?.boolValue, true)
        XCTAssertEqual(value["size"]?.numberValue, 12.5)
        XCTAssertEqual(value["inner"]?.objectValue, ["k": .null])
        XCTAssertNil(value["missing"])
        XCTAssertNil(value["name"]?.numberValue)
        XCTAssertNil(AgentJSON.array([])["name"])
        // Only an object or an array counts as JSON inside a piece of text.
        XCTAssertEqual(AgentJSON(jsonText: #" {"a": 1}"#), .object(["a": .number(1)]))
        XCTAssertEqual(AgentJSON(jsonText: "[1]"), .array([.number(1)]))
        XCTAssertNil(AgentJSON(jsonText: "12"))
        XCTAssertNil(AgentJSON(jsonText: "Budget.xlsx"))
        XCTAssertNil(AgentJSON(jsonText: "{not json}"))
    }
}
