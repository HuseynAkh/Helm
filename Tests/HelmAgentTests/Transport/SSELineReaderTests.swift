import XCTest
@testable import HelmAgent

/// The reader cuts bytes into lines as an event stream does, keeps empty lines, and stops a line that never ends.
final class SSELineReaderTests: XCTestCase {
    private func lines(_ text: String, cap: Int = 1_000) throws -> [String] {
        var reader = SSELineReader(lineCap: cap)
        var found = try reader.take(contentsOf: Array(text.utf8))
        if let last = reader.finish() { found.append(last) }
        return found
    }

    func testLinesEndAtEachKindOfLineBreak() throws {
        XCTAssertEqual(try lines("data: a\ndata: b\n"), ["data: a", "data: b"])
        XCTAssertEqual(try lines("data: a\r\ndata: b\r\n"), ["data: a", "data: b"])
        XCTAssertEqual(try lines("data: a\rdata: b\r"), ["data: a", "data: b"])
        XCTAssertEqual(try lines("one\r\ntwo\nthree\rfour"), ["one", "two", "three", "four"])
    }

    func testALineSplitAcrossChunksComesOutWhole() throws {
        var reader = SSELineReader(lineCap: 1_000)
        XCTAssertEqual(try reader.take(contentsOf: Array("data: {\"ty".utf8)), [])
        XCTAssertEqual(try reader.take(contentsOf: Array("pe\":\"ping\"}".utf8)), [])
        XCTAssertEqual(try reader.take(contentsOf: Array("\nda".utf8)), ["data: {\"type\":\"ping\"}"])
        XCTAssertEqual(try reader.take(contentsOf: Array("ta: x\r".utf8)), ["data: x"])
        // The line feed of a CR LF pair that was split between chunks ends nothing more.
        XCTAssertEqual(try reader.take(contentsOf: Array("\n".utf8)), [])
        XCTAssertNil(reader.finish())
    }

    func testAByteAtATimeGivesTheSameLines() throws {
        let text = "event: message_start\ndata: {\"a\":1}\r\n\r\n: comment\ndata: [DONE]\n"
        var reader = SSELineReader(lineCap: 1_000)
        var found: [String] = []
        for byte in text.utf8 {
            if let line = try reader.take(byte) { found.append(line) }
        }
        XCTAssertEqual(found, ["event: message_start", "data: {\"a\":1}", "", ": comment", "data: [DONE]"])
    }

    func testEmptyLinesAreKept() throws {
        XCTAssertEqual(try lines("data: a\n\ndata: b\n\n"), ["data: a", "", "data: b", ""])
        XCTAssertEqual(try lines("\n\n\n"), ["", "", ""])
        XCTAssertEqual(try lines("\r\n\r\n"), ["", ""])
        XCTAssertEqual(try lines("\r\r"), ["", ""])
    }

    func testTextAfterTheLastBreakIsHandedOnAtTheEnd() throws {
        XCTAssertEqual(try lines("data: a\ndata: b"), ["data: a", "data: b"])
        XCTAssertEqual(try lines(""), [])
        var reader = SSELineReader(lineCap: 10)
        XCTAssertEqual(try reader.take(contentsOf: Array("tail".utf8)), [])
        XCTAssertEqual(reader.finish(), "tail")
        XCTAssertNil(reader.finish())
    }

    func testTextOutsideASCIIIsDecodedAndBrokenBytesAreReplaced() throws {
        XCTAssertEqual(try lines("data: Привет, 東京 🙂\n"), ["data: Привет, 東京 🙂"])
        var reader = SSELineReader(lineCap: 100)
        let found = try reader.take(contentsOf: [0x61, 0xFF, 0x62, 0x0A])
        XCTAssertEqual(found, ["a\u{FFFD}b"])
    }

    func testTheCapCountsBytesAndAllowsALineOfExactlyThatMany() throws {
        XCTAssertEqual(try lines("12345\n", cap: 5), ["12345"])
        // Two bytes a letter: five bytes don't hold three letters.
        XCTAssertThrowsError(try lines("ééé\n", cap: 5)) { XCTAssertEqual($0 as? SSELineReader.LineTooLong, .init()) }
        // The line break isn't counted, and the count starts again on each line.
        XCTAssertEqual(try lines("12345\n12345\r\n12345", cap: 5), ["12345", "12345", "12345"])
    }

    func testAnEndlessLineIsStoppedAtTheCap() {
        var reader = SSELineReader(lineCap: 4_096)
        var taken = 0
        XCTAssertThrowsError(try {
            for _ in 0..<1_000_000 {
                _ = try reader.take(UInt8(ascii: "x"))
                taken += 1
            }
        }()) { XCTAssertTrue($0 is SSELineReader.LineTooLong) }
        XCTAssertEqual(taken, 4_096)
    }
}
