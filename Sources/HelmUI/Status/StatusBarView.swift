// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

/// Always-visible 24-point status with legacy wording; capacity is injected (F-064, B-058).
public struct StatusBarView: View {
    private let text: String
    public init(status: StatusPresentation) { text = StatusText.format(status) }
    public var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .overlay(alignment: .top) { Divider() }
            .accessibilityLabel(text)
    }
}
