import Foundation

/// Literal template tokens preserved from F-055's BatchRenameView.
public enum RenameToken: String, CaseIterable, Sendable {
    case originalName = "[Original Name]"
    case counter = "[Counter]"
    case date = "[Date]"
}

/// F-055 modes operate on the basename and retain the final NSString extension.
public enum BatchRenameRule: Sendable, Equatable {
    case addText(prepend: String, append: String)
    case findReplace(find: String, replacement: String)
    case template(String, counterStart: Int)

    public func name(for original: String, index: Int, date: Date,
                     timeZone: TimeZone = .current) throws -> String {
        let base = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        let renamed: String
        switch self {
        case let .addText(prepend, append): renamed = prepend + base + append
        case let .findReplace(find, replacement):
            renamed = find.isEmpty ? base : base.replacingOccurrences(of: find, with: replacement)
        case let .template(template, start):
            let (counter, overflow) = start.addingReportingOverflow(index)
            guard !overflow else { throw BatchRenameRuleError.counterOverflow }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            renamed = template.replacingOccurrences(of: RenameToken.originalName.rawValue, with: base)
                .replacingOccurrences(of: RenameToken.counter.rawValue, with: String(counter))
                .replacingOccurrences(of: RenameToken.date.rawValue, with: formatter.string(from: date))
        }
        return renamed + (ext.isEmpty ? "" : ".\(ext)")
    }
}

/// Reports unrepresentable F-055 counter input instead of trapping.
public enum BatchRenameRuleError: Error, Sendable { case counterOverflow }
