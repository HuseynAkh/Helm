// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

/// Always-visible 24-point status with legacy wording; capacity is injected (F-064, B-058).
/// During and after a search with a model's help, its line takes the place of the usual words. When that line has
/// the queries that ran, it's a button, and pressing it lists them, one per line.
public struct StatusBarView: View {
    private let text: String
    private let queries: [String]
    @State private var showsQueries = false
    public init(status: StatusPresentation, aiSearch: AISearchStatus? = nil) {
        text = aiSearch?.text ?? StatusText.format(status)
        queries = aiSearch?.queries ?? []
    }
    public var body: some View {
        line
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .overlay(alignment: .top) { Divider() }
    }
    @ViewBuilder private var line: some View {
        if queries.isEmpty {
            words.accessibilityLabel(Text(verbatim: text))
        } else {
            Button { showsQueries.toggle() } label: { words }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: text))
                .popover(isPresented: $showsQueries, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(queries.enumerated()), id: \.offset) { _, query in
                            Text(verbatim: query).font(.system(size: 12)).textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 420, alignment: .leading)
                }
        }
    }
    private var words: some View {
        Text(verbatim: text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
