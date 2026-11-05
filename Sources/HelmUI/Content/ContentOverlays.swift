// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
#if canImport(AppKit)
import AppKit
import SwiftUI
import HelmCore

/// Non-intercepting F-035 marquee; parent feeds the same rectangle to GridGeometry selection.
public struct RubberBandOverlay: View {
    private let geometry: GridGeometry
    private let rectangle: CGRect?
    public init(geometry: GridGeometry, rectangle: CGRect?) {
        self.geometry = geometry; self.rectangle = rectangle
    }
    public var body: some View {
        ZStack(alignment: .topLeading) {
            if let rect = ContentLeafPresentation.rubberBand(rectangle, geometry: geometry) {
                Rectangle().fill(Color.accentColor.opacity(0.15))
                    .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: 1) }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: geometry.availableWidth, height: geometry.contentHeight, alignment: .topLeading)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// F-067 target decoration follows the accepted Core proposal, never an insertion gap (B-074).
public struct DropHighlightOverlay: View {
    private let proposal: HelmCore.DropProposal?
    private let target: DropHighlight
    public init(proposal: HelmCore.DropProposal?, target: DropHighlight) {
        self.proposal = proposal; self.target = target
    }
    public var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(ContentLeafPresentation.isHighlighted(target, proposal: proposal)
                          ? Color.accentColor : Color.clear, lineWidth: 2)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// F-067 cursor accessory displays planner feedback and the complete drag count (B-045).
public struct DragBadgeView: View {
    private let feedback: DropFeedback
    private let count: Int
    public init(feedback: DropFeedback, count: Int) { self.feedback = feedback; self.count = max(0, count) }
    public var body: some View {
        let badge: ContentBadge = ContentLeafPresentation.dragBadge(feedback)
        HStack(spacing: 4) {
            Image(systemName: badge.symbol)
            Text(String(count)).monospacedDigit()
        }
        .font(.caption).padding(6).background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .ignore).accessibilityLabel("\(badge.label), \(count) items")
        .allowsHitTesting(false)
    }
}
#endif
