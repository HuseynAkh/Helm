// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI

/// F-061 details stay collapsed without formatting outcomes; pages bound view work (B-010).
struct OperationDetailsView: View {
    let row: OperationRowModel
    @State private var expanded = false
    @State private var page = 0
    init(row: OperationRowModel) { self.row = row }
    var body: some View {
        DisclosureGroup("Details", isExpanded: $expanded) {
            if expanded {
                let currentPage = min(page, max(0, row.detailPageCount - 1))
                ForEach(Array(row.detailPage(currentPage).enumerated()), id: \.offset) { _, detail in
                    Text(detail).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Outcome indices remain stable within the immutable result.
                .id(currentPage)
                if row.detailPageCount > 1 {
                    HStack {
                        Button("Previous") { page = currentPage - 1 }.disabled(currentPage == 0)
                        Text("Page \(currentPage + 1) of \(row.detailPageCount)").font(.caption)
                        Button("Next") { page = currentPage + 1 }
                            .disabled(currentPage + 1 >= row.detailPageCount)
                    }
                }
            }
        }
    }
}
