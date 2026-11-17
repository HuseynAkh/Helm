#if os(macOS)
import AppKit
import HelmAgent
import HelmCore

/// The bytes of a file an AI panel plan makes, from the text the model wrote. Text and code are the text in UTF-8.
/// RTF and Word are made by the text system from the text alone: one paragraph a line, in the document's own default
/// font, with nothing else in them. Nothing is read to make them: no file, no address, no picture.
enum AgentNewFileContents {
    /// Nil when the text system couldn't make the document.
    static func data(name: ValidFileName, text: String) -> Data? {
        switch AgentNewName.fileExtension(of: name.value) {
        case "rtf":
            let string = paragraphs(text)
            return string.rtf(from: NSRange(location: 0, length: string.length))
        case "docx":
            // The text system's own writer, which makes the zip file in memory and reads nothing.
            let string = paragraphs(text), whole = NSRange(location: 0, length: string.length)
            return try? string.data(from: whole, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        default:
            return Data(text.utf8)
        }
    }

    /// The text with every line break written as a paragraph's end.
    private static func paragraphs(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }
}
#endif
