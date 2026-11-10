#if os(macOS)
import AppKit
import HelmCore
import SwiftUI

/// The content area's status page, decided by `ContentStatePresentation`.
/// A problem sits on a small card of system material with a way forward; an empty folder is just a quiet symbol
/// and a line, as on Nautilus's status pages. System colours and materials only, so it follows light and dark.
struct ContentStateView: View {
    let state: ContentState?
    let perform: (ContentStateAction) -> Void

    var body: some View {
        if let state {
            switch state.style {
            case .empty: ContentStateEmptyPage(state: state)
            case .problem, .waiting: ContentStateCard(state: state, perform: perform)
            }
        }
    }
}

private struct ContentStateEmptyPage: View {
    let state: ContentState
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: state.symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(state.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

private struct ContentStateCard: View {
    let state: ContentState
    let perform: (ContentStateAction) -> Void

    /// Waiting is ordinary; a refusal or a missing place needs the eye.
    private var tint: Color { state.style == .waiting ? .accentColor : .orange }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(tint.opacity(0.13))
                Image(systemName: state.symbol)
                    .font(.system(size: 26, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
            .frame(width: 60, height: 60)
            .accessibilityHidden(true)
            .padding(.bottom, 14)
            Text(state.title)
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let message = state.message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            if !state.buttons.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons }
                    VStack(spacing: 8) { buttons }
                }
                .padding(.top, 18)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(maxWidth: 440)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            // System material, lifted a little: lighter than the window in dark mode, as raised surfaces are.
            shape.fill(.regularMaterial)
            shape.fill(Self.lift)
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Self.edge, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        .padding(16)
    }

    private static let lift = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 1, alpha: 0.35)
    })
    private static let edge = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.07)
    })

    /// No keyboard shortcuts: Return belongs to the files, and the card mustn't take it over.
    @ViewBuilder private var buttons: some View {
        ForEach(state.buttons, id: \.self) { button in
            if button.isPrimary {
                Button(button.title) { perform(button.action) }.buttonStyle(.borderedProminent)
            } else {
                Button(button.title) { perform(button.action) }.buttonStyle(.bordered)
            }
        }
    }
}

/// Holds the status page over the content area. An empty state lets clicks and drops through to the listing
/// underneath, so you can still drop into an empty folder or right-click it for New Folder.
@MainActor final class ContentStateHostingView: NSHostingView<ContentStateView> {
    var passesThrough = true
    required init(rootView: ContentStateView) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { passesThrough ? nil : super.hitTest(point) }
}

/// What the window shows instead of its listing, and the quiet retry while macOS's question is unanswered.
@MainActor final class ContentStatePage {
    let view = ContentStateHostingView(rootView: ContentStateView(state: nil, perform: { _ in }))
    private(set) var state: ContentState?
    /// A state shown for a screenshot in place of the tab's own; nil shows the tab's.
    var preview: ContentState?
    private var retry: Task<Void, Never>?
    /// While the waiting card shows, the place is tried again after this long, then twice as long each time up to
    /// `longestRetryInterval`, and no more than `retryLimit` times. Helm also tries again whenever it comes back to
    /// the front, which is when an answered question usually shows, and Try Again starts the count over.
    var retryInterval: TimeInterval = 3
    var longestRetryInterval: TimeInterval = 30
    var retryLimit = 8
    private(set) var retries = 0
    /// What VoiceOver was last told about a card.
    private(set) var lastAnnouncement: String?

    /// `retryWaiting` runs after each interval while a waiting card stays up, until the limit.
    func show(_ next: ContentState?, perform: @escaping (ContentStateAction) -> Void, retryWaiting: @escaping () -> Void) {
        let changed = next != state
        if changed || view.isHidden != (next == nil) {
            state = next
            view.rootView = ContentStateView(state: next, perform: perform)
            view.isHidden = next == nil
            view.passesThrough = next?.style == .empty
        }
        if changed {
            retries = 0
            retry?.cancel(); retry = nil
            if let next, next.style != .empty { announce(next) }
        }
        guard next?.style == .waiting else { retry?.cancel(); retry = nil; return }
        guard retry == nil, retries < retryLimit else { return }
        let delay = min(longestRetryInterval, retryInterval * pow(2, Double(retries)))
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.retry = nil
            self.retries += 1
            retryWaiting()
        }
    }

    /// Try Again starts the quiet retries over.
    func restartRetries() { retries = 0 }

    /// A card that replaces the listing is news, and keyboard focus has just left the listing: VoiceOver says
    /// what happened and moves to the card.
    private func announce(_ state: ContentState) {
        let text = [state.title, state.message].compactMap { $0 }.joined(separator: ". ")
        lastAnnouncement = text
        NSAccessibility.post(element: view, notification: .layoutChanged, userInfo: [.uiElements: [view]])
        let element: Any = view.window.map { $0 as Any } ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
#endif
