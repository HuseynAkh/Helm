// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore
import HelmOperations

/// F-061 rows retain partial-failure outcomes until the host removes them (B-038/B-100).
public struct OperationsPanel: View {
    private let rows: [OperationRowModel]
    private let dismiss: (OperationID) -> Void
    private let cancel: (OperationID) -> Void
    public init(rows: [OperationRowModel], cancel: @escaping (OperationID) -> Void, dismiss: @escaping (OperationID) -> Void) {
        self.rows = rows; self.cancel = cancel; self.dismiss = dismiss
    }
    public var body: some View {
        VStack(spacing: 0) {
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.title).font(.callout).fontWeight(.medium)
                                Text(row.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    .help(row.progress?.currentName ?? row.status)
                            }
                            Spacer()
                            if row.result == nil {
                                Button { cancel(row.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).disabled(!row.canCancel)
                                    .accessibilityLabel("Cancel \(row.title)")
                            } else {
                                Button("Dismiss") { dismiss(row.id) }
                            }
                        }
                        if row.result == nil {
                            if let fraction = row.fraction { ProgressView(value: fraction) }
                            else { ProgressView().controlSize(.small) }
                        }
                        if row.requiresReconciliation {
                            Text("Some items may be only partly done. Check them before trying again.").font(.caption).foregroundStyle(.orange)
                        }
                        if row.hasDetails { OperationDetailsView(row: row) }
                    }.padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
        .background(.bar)
        }
    }
}
