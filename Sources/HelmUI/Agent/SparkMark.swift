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

    /// Four points on the middles of `rect`'s edges, joined by sides that curve in towards the centre.
    public static func path(in rect: CGRect) -> CGPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let points = [CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.midY),
                      CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY)]
        // How far each side's bend stays from the centre: small, so the spark has a narrow waist.
        let waist: CGFloat = 0.2
        let path = CGMutablePath()
        path.move(to: points[0])
        for index in points.indices {
            let from = points[index], to = points[(index + 1) % points.count]
            let control = CGPoint(x: center.x + ((from.x + to.x) / 2 - center.x) * waist,
                                  y: center.y + ((from.y + to.y) / 2 - center.y) * waist)
            path.addQuadCurve(to: to, control: control)
        }
        path.closeSubpath()
        return path
    }

    /// The spark in a square image. Unlit it's a template in the label colour, so menus and toolbars tint it as they
    /// tint symbols; lit it's filled with the gradient. Drawn flat, with no effect a capture would miss.
    public static func image(size: CGFloat, lit: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let shape = path(in: bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08))
            context.addPath(shape)
            if lit, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                              colors: gradientColors.map(\.cgColor) as CFArray, locations: [0, 0.5, 1]) {
                context.clip()
                context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.maxY),
                                           end: CGPoint(x: bounds.midX, y: bounds.minY), options: [])
            } else {
                context.setFillColor(NSColor.labelColor.cgColor)
                context.fillPath()
            }
            return true
        }
        image.isTemplate = !lit
        return image
    }
}
#endif
