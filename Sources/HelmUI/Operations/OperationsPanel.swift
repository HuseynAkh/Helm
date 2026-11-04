// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

/// F-061 rows retain partial-failure outcomes until the host removes them (B-038/B-100).
public struct OperationsPanel: View {
    private let rows: [OperationRowModel]
    private let cancel: (OperationID) -> Void
    public init(rows: [OperationRowModel], cancel: @escaping (OperationID) -> Void) {
        self.rows = rows; self.cancel = cancel
    }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.title).font(.caption).fontWeight(.medium)
                                Text(row.status).font(.caption2)
                                if let name = row.progress?.currentName { Text(name).lineLimit(1).help(name) }
                            }
                            Spacer()
                            if row.result == nil {
                                Button { cancel(row.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).disabled(!row.canCancel)
                                    .accessibilityLabel("Cancel \(row.title)")
                            }
                        }
                        if row.result == nil {
                            if let fraction = row.fraction { ProgressView(value: fraction) }
                            else { ProgressView().controlSize(.small) }
                        }
                        if !row.details.isEmpty {
                            // MAC-VERIFY: disclosure expansion, text selection and keyboard focus in hosted panel.
                            DisclosureGroup("Details") {
                                ForEach(Array(row.details.enumerated()), id: \.offset) { _, detail in
                                    Text(detail).font(.caption).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
    }
}
