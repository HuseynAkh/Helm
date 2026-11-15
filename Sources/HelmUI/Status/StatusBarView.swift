import SwiftUI
import HelmCore

/// Always-visible 24-point status with legacy wording; capacity is injected (F-064, B-058).
/// During and after a search with a model's help, its line takes the place of the usual words. When that line has
/// the queries that ran, it's a button, and pressing it lists them, one per line.
public struct StatusBarView: View {
    /// The words on show: the AI line during such a search, the usual words otherwise.
    let text: String
    let queries: [String]
    /// Whether the line is a button that lists the queries.
    var isPressable: Bool { !queries.isEmpty }
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
        if !isPressable {
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
    /// The words; while they open the list of queries, the spark before them and a small chevron after say that
    /// they come from AI and can be pressed.
    @ViewBuilder private var words: some View {
        let plain = Text(verbatim: text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        if isPressable {
            HStack(spacing: 5) {
                Image(nsImage: SparkMark.image(size: 10, lit: false)).renderingMode(.template)
                    .foregroundStyle(.secondary).accessibilityHidden(true)
                plain
                Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
        } else {
            plain
        }
    }
}
