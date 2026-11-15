import Foundation

/// Cuts the bytes of a streamed reply into lines, one byte at a time, so a line is handed on as soon as it ends.
///
/// A line ends at a line feed, a carriage return, or the two together, as event streams allow. An empty line is a
/// line too: in an event stream it ends an event, so it is handed on rather than dropped. Nothing here knows about
/// events; the adapters skip comment lines and take the text after `data:`.
///
/// A line may hold at most `lineCap` bytes. One byte more and `take` throws, so a reply that never ends a line
/// can't grow without bound.
struct SSELineReader {
    /// A line went past the cap before it ended.
    struct LineTooLong: Error, Equatable {}

    let lineCap: Int
    private var pending: [UInt8] = []
    /// The last byte was a carriage return, so a line feed right after it ends nothing more.
    private var afterReturn = false

    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    init(lineCap: Int) {
        self.lineCap = lineCap
    }

    /// Takes one byte. Answers the line it ends, if it ends one.
    mutating func take(_ byte: UInt8) throws -> String? {
        switch byte {
        case Self.lineFeed:
            if afterReturn {
                afterReturn = false
                return nil
            }
            return endLine()
        case Self.carriageReturn:
            afterReturn = true
            return endLine()
        default:
            afterReturn = false
            guard pending.count < lineCap else { throw LineTooLong() }
            pending.append(byte)
            return nil
        }
    }

    /// Takes a run of bytes. Answers the lines they end, in order.
    mutating func take<Bytes: Sequence>(contentsOf bytes: Bytes) throws -> [String] where Bytes.Element == UInt8 {
        var lines: [String] = []
        for byte in bytes {
            if let line = try take(byte) { lines.append(line) }
        }
        return lines
    }

    /// The text after the last line break, when the reply ends without one. Nil when nothing is left.
    mutating func finish() -> String? {
        afterReturn = false
        return pending.isEmpty ? nil : endLine()
    }

    private mutating func endLine() -> String {
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return line
    }
}
