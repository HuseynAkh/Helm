#if os(macOS)
import AppKit

/// Helm's four-point spark, the mark of AI mode: the header's button, the Settings tab, the search field's toggle and
/// the AI mode screen all draw this one shape.
public enum SparkMark {
    /// Amber, coral and violet, from top to bottom.
    public static let gradientColors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.71, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.44, blue: 0.38, alpha: 1),
        NSColor(srgbRed: 0.56, green: 0.36, blue: 0.96, alpha: 1)
    ]

    /// How far along each point's own axis a side's curve starts to bend, and how far it leans towards the next point,
    /// as shares of the distance from the centre. The first keeps the points long and sharp; the second, small, gives
    /// the spark its narrow waist.
    private static let reach: CGFloat = 0.30
    private static let lean: CGFloat = 0.06

    /// Four points on the middles of `rect`'s edges, joined by sides that curve in towards the centre. Each side
    /// leaves its point along that point's axis, so the points stay sharp at any size.
    public static func path(in rect: CGRect) -> CGPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // From the centre to each point: top, right, bottom, left.
        let arms = [CGVector(dx: 0, dy: rect.height / 2), CGVector(dx: rect.width / 2, dy: 0),
                    CGVector(dx: 0, dy: -rect.height / 2), CGVector(dx: -rect.width / 2, dy: 0)]
        func point(_ first: CGVector, _ firstShare: CGFloat, _ second: CGVector, _ secondShare: CGFloat) -> CGPoint {
            CGPoint(x: center.x + first.dx * firstShare + second.dx * secondShare,
                    y: center.y + first.dy * firstShare + second.dy * secondShare)
        }
        let path = CGMutablePath()
        path.move(to: point(arms[0], 1, arms[0], 0))
        for index in arms.indices {
            let from = arms[index], to = arms[(index + 1) % arms.count]
            path.addCurve(to: point(to, 1, to, 0), control1: point(from, reach, to, lean),
                          control2: point(to, reach, from, lean))
        }
        path.closeSubpath()
        return path
    }

    /// The spark in a square image. Unlit it's a template in the label colour, so menus, buttons and toolbars tint it
    /// as they tint symbols; lit it's filled with the gradient. Drawn flat, with no effect a capture would miss.
    public static func image(size: CGFloat, lit: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let rect = markRect(in: bounds)
            if lit {
                drawGradient(in: rect, context: context, turn: 0)
            } else {
                fill(in: rect, context: context, color: NSColor.labelColor)
            }
            return true
        }
        image.isTemplate = !lit
        return image
    }

    /// Where the spark sits in a square: a little in from the edges, so its points aren't cut by antialiasing.
    static func markRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08)
    }

    /// The spark in one plain colour, resolved for the appearance being drawn.
    static func fill(in rect: CGRect, context: CGContext, color: NSColor) {
        context.saveGState()
        context.addPath(path(in: rect))
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    /// The spark filled with the gradient, which runs from amber at the top to violet at the bottom. `turn` (0 to 1)
    /// turns the gradient's direction round the centre: a slow turn is the shimmer while a request is open, and 0 is
    /// the still mark. In unflipped coordinates.
    static func drawGradient(in rect: CGRect, context: CGContext, turn: CGFloat) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: gradientColors.map(\.cgColor) as CFArray, locations: [0, 0.5, 1]) else { return }
        let angle = turn * 2 * .pi
        let radius = max(rect.width, rect.height) / 2
        let offset = CGVector(dx: sin(angle) * radius, dy: cos(angle) * radius)
        context.saveGState()
        context.addPath(path(in: rect))
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX + offset.dx, y: rect.midY + offset.dy),
                                   end: CGPoint(x: rect.midX - offset.dx, y: rect.midY - offset.dy),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }
}
#endif
