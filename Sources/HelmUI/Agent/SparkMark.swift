#if os(macOS)
import AppKit

/// Helm's mark of AI mode, the trefoil: one closed line that loops three times and crosses itself three times, over
/// and under in turn, with a small gap where it passes under itself. The header's button, the Settings tab, the
/// search field's toggle, the status bar, the panel and the AI mode screen all draw this one shape. Its name stays
/// `SparkMark`, the name of the four-point spark it replaced, so every caller keeps working.
public enum SparkMark {
    /// Amber, coral and violet, from top to bottom.
    public static let gradientColors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.71, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.44, blue: 0.38, alpha: 1),
        NSColor(srgbRed: 0.56, green: 0.36, blue: 0.96, alpha: 1)
    ]

    /// The knot's line in `rect` as one shape to fill, without its gaps: its outer edge touches `rect`'s two sides
    /// that are furthest apart, and it's as heavy as the mark is drawn at that size.
    public static func path(in rect: CGRect) -> CGPath {
        let layout = Layout(ink: rect)
        return layout.line.copy(strokingWithWidth: layout.weight, lineCap: .round, lineJoin: .round, miterLimit: 4)
    }

    /// The mark in a square image. Unlit it's a template in the label colour, so menus, buttons and toolbars tint it
    /// as they tint symbols; lit it's drawn in the gradient. Drawn flat, with no effect a capture would miss.
    /// It's drawn again at whatever size it's shown, and its line is as heavy as the shown size needs: Settings'
    /// toolbar shows its tab images larger than they are, and a line weighed for the smaller size would come out
    /// heavy there.
    public static func image(size: CGFloat, lit: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let zoom = shownScale(of: context)
            let paint: Paint = lit ? .gradient(turn: 0) : .plain(NSColor.labelColor.cgColor)
            draw(in: bounds, context: context, paint: paint, zoom: zoom)
            return true
        }
        image.isTemplate = !lit
        return image
    }

    /// Where the knot's ink sits in the mark's square: a little in from the edges, so at 18 points it's about
    /// 15.5 points across, the size of the header's 15-point symbols beside it.
    static func markRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: bounds.width * inset, dy: bounds.height * inset)
    }
    static let inset: CGFloat = 0.07

    /// The mark in one plain colour, resolved for the appearance being drawn, in the square `rect`.
    static func fill(in rect: CGRect, context: CGContext, color: NSColor) {
        draw(in: rect, context: context, paint: .plain(color.cgColor))
    }

    /// The mark in the gradient, which runs from amber at the top to violet at the bottom, in the square `rect`.
    /// `turn` (0 to 1) turns the gradient's direction round the centre: a slow turn is the shimmer while a request
    /// is open, and 0 is the still mark. In unflipped coordinates.
    static func drawGradient(in rect: CGRect, context: CGContext, turn: CGFloat) {
        draw(in: rect, context: context, paint: .gradient(turn: turn))
    }

    // MARK: Weight

    /// The line's width in points for a knot `ink` points across: 1 point at the status bar's 10-point mark, about
    /// 1.45 at the header's 18, and a little over 6 % of the size from 64 points up, so it stays crisp small and
    /// light large.
    static func weight(ink: CGFloat) -> CGFloat {
        0.45 + 0.064 * ink
    }
    /// The gap either side of the strand on top, where the line passes under itself: never under half a point, so
    /// it's a whole pixel on a Retina screen at the smallest sizes.
    static func gap(weight: CGFloat) -> CGFloat {
        max(weight * 0.36, 0.5)
    }
    /// How dark the strand underneath is right at the gap, fading out over about one and a half line widths: lighter
    /// on the small marks, where the shade would cover most of the short strands between crossings and muddy them.
    static func shadeStrength(ink: CGFloat) -> CGFloat {
        0.38 * min(1, max(0.35, (ink - 4) / 26))
    }

    /// How many times larger than its own size an image is being shown, from the scale its drawing context has. A
    /// Mac's screen is 1x or 2x, so a scale over 2 is a Retina screen showing the image enlarged, and a scale between
    /// 1 and 2 is either a Retina screen at the image's size or a 1x screen enlarging it; the first is far the more
    /// common, so it's read as that.
    static func shownScale(of context: CGContext) -> CGFloat {
        let scale = hypot(context.ctm.a, context.ctm.b)
        return scale > 2.05 ? scale / 2 : 1
    }

    // MARK: The knot

    /// The knot's line, one loop at the top: two turns one way and one, slower, the other, the trefoil's own
    /// drawing, with a small fourth harmonic that leans each loop into a teardrop. Sampled once, centred on its
    /// bounds and scaled so its larger half-extent is 1, in unflipped unit coordinates.
    struct Knot {
        /// Where the line crosses itself: the point, the two strands' positions along the line (arc length, unit
        /// coordinates), and the sine of the angle between them.
        struct Crossing { let point: CGPoint; let over: CGFloat; let under: CGFloat; let sine: CGFloat }
        let points: [CGPoint]
        /// The running length along the line: `lengths[i]` is where segment `i` starts; the last is the whole length.
        let lengths: [CGFloat]
        let crossings: [Crossing]
        var total: CGFloat { lengths[lengths.count - 1] }

        init(samples: Int = 1024) {
            var raw = (0..<samples).map { index -> CGPoint in
                let t = CGFloat(index) / CGFloat(samples) * 2 * .pi
                let x = cos(2 * t) + 0.6 * cos(-t) + 0.06 * cos(-4 * t)
                let y = sin(2 * t) + 0.6 * sin(-t) + 0.06 * sin(-4 * t)
                // A quarter turn puts one loop at the top.
                return CGPoint(x: -y, y: x)
            }
            let xs = raw.map(\.x), ys = raw.map(\.y)
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0, minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            let half = max(maxX - minX, maxY - minY) / 2
            raw = raw.map { CGPoint(x: ($0.x - (minX + maxX) / 2) / half, y: ($0.y - (minY + maxY) / 2) / half) }
            points = raw
            var running: [CGFloat] = [0]
            for index in raw.indices {
                let a = raw[index], b = raw[(index + 1) % raw.count]
                running.append(running[index] + hypot(b.x - a.x, b.y - a.y))
            }
            lengths = running
            crossings = Self.crossings(raw, running)
        }

        /// Every place the line crosses itself, with over and under taking turns along the line, as a knot is drawn.
        static func crossings(_ points: [CGPoint], _ lengths: [CGFloat]) -> [Crossing] {
            let count = points.count
            var hits: [(point: CGPoint, first: CGFloat, second: CGFloat, sine: CGFloat)] = []
            for i in 0..<count {
                let p1 = points[i], p2 = points[(i + 1) % count]
                let r = CGVector(dx: p2.x - p1.x, dy: p2.y - p1.y)
                for j in (i + 2)..<max(i + 2, count) where !(i == 0 && j == count - 1) {
                    let q1 = points[j], q2 = points[(j + 1) % count]
                    if max(q1.x, q2.x) < min(p1.x, p2.x) || min(q1.x, q2.x) > max(p1.x, p2.x)
                        || max(q1.y, q2.y) < min(p1.y, p2.y) || min(q1.y, q2.y) > max(p1.y, p2.y) { continue }
                    let s = CGVector(dx: q2.x - q1.x, dy: q2.y - q1.y)
                    let cross = r.dx * s.dy - r.dy * s.dx
                    guard abs(cross) > 1e-12 else { continue }
                    let qp = CGVector(dx: q1.x - p1.x, dy: q1.y - p1.y)
                    let t = (qp.dx * s.dy - qp.dy * s.dx) / cross
                    let u = (qp.dx * r.dy - qp.dy * r.dx) / cross
                    guard t >= 0, t < 1, u >= 0, u < 1 else { continue }
                    hits.append((CGPoint(x: p1.x + r.dx * t, y: p1.y + r.dy * t),
                                 lengths[i] + (lengths[i + 1] - lengths[i]) * t,
                                 lengths[j] + (lengths[j + 1] - lengths[j]) * u,
                                 abs(cross) / (hypot(r.dx, r.dy) * hypot(s.dx, s.dy))))
                }
            }
            // Along the line the crossings come over, under, over, ...: the first pass is over at every other one.
            var passes: [(at: CGFloat, hit: Int)] = []
            for (index, hit) in hits.enumerated() { passes += [(hit.first, index), (hit.second, index)] }
            passes.sort { $0.at < $1.at }
            var over: [Int: CGFloat] = [:], under: [Int: CGFloat] = [:]
            for (rank, pass) in passes.enumerated() {
                if rank % 2 == 0 { over[pass.hit] = pass.at } else { under[pass.hit] = pass.at }
            }
            return hits.indices.compactMap { index in
                guard let o = over[index], let u = under[index] else { return nil }
                return Crossing(point: hits[index].point, over: o, under: u, sine: hits[index].sine)
            }
        }

        /// The point `s` along the line (unit coordinates), going round as many times as it takes.
        func point(at s: CGFloat) -> CGPoint {
            var s = s.truncatingRemainder(dividingBy: total)
            if s < 0 { s += total }
            var low = 0, high = points.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lengths[middle] <= s { low = middle } else { high = middle - 1 }
            }
            let a = points[low], b = points[(low + 1) % points.count]
            let span = lengths[low + 1] - lengths[low]
            let t = span > 0 ? (s - lengths[low]) / span : 0
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }
    static let knot = Knot()

    /// The knot laid out in one ink box: its weight there, where its unit coordinates land, and its whole line.
    struct Layout {
        let weight: CGFloat
        let center: CGPoint
        let scale: CGFloat
        let line: CGPath

        init(ink: CGRect, zoom: CGFloat = 1) {
            let side = min(ink.width, ink.height)
            weight = SparkMark.weight(ink: side * zoom) / zoom
            center = CGPoint(x: ink.midX, y: ink.midY)
            scale = max(side / 2 - weight / 2, 0.1)
            let line = CGMutablePath()
            let center = center, scale = scale
            for (index, point) in SparkMark.knot.points.enumerated() {
                let placed = CGPoint(x: center.x + point.x * scale, y: center.y + point.y * scale)
                if index == 0 { line.move(to: placed) } else { line.addLine(to: placed) }
            }
            line.closeSubpath()
            self.line = line
        }

        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: center.x + point.x * scale, y: center.y + point.y * scale)
        }

        /// A stretch of the line from `half` points before position `s` (unit arc length) to `half` points after it.
        func piece(at s: CGFloat, half: CGFloat) -> CGPath {
            let knot = SparkMark.knot
            let path = CGMutablePath()
            let end = s + half / scale
            let step = knot.total / CGFloat(knot.points.count) / 2
            var at = s - half / scale
            path.move(to: place(knot.point(at: at)))
            while at < end {
                at = min(at + step, end)
                path.addLine(to: place(knot.point(at: at)))
            }
            return path
        }
    }

    // MARK: Drawing

    enum Paint { case plain(CGColor), gradient(turn: CGFloat) }

    /// Draws the mark in the square `rect`. All of it happens in one transparency layer, so the gaps are clear over
    /// whatever is behind the mark, and the plain colour's own alpha is applied once, to the whole mark.
    /// `zoom` is how many times larger than `rect` the mark is shown, so its weight and gap are the shown size's.
    static func draw(in rect: CGRect, context: CGContext, paint: Paint, zoom: CGFloat = 1) {
        let layout = Layout(ink: markRect(in: rect), zoom: zoom)
        let w = layout.weight, g = gap(weight: w * zoom) / zoom
        // One device pixel, in the context's points, for the edges' antialiasing.
        let pixel = 1 / max(abs(context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width), 1)
        let side = min(rect.width, rect.height)

        func fillPaint(clip: CGPath) {
            context.saveGState()
            context.addPath(clip)
            context.clip()
            switch paint {
            case .plain(let color):
                context.setFillColor(color.copy(alpha: 1) ?? color)
                context.fill(rect.insetBy(dx: -w, dy: -w))
            case .gradient(let turn):
                guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                colors: gradientColors.map(\.cgColor) as CFArray,
                                                locations: [0, 0.5, 1]) else { break }
                let angle = turn * 2 * .pi
                let radius = side / 2
                let offset = CGVector(dx: sin(angle) * radius, dy: cos(angle) * radius)
                context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX + offset.dx, y: rect.midY + offset.dy),
                                           end: CGPoint(x: rect.midX - offset.dx, y: rect.midY - offset.dy),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            context.restoreGState()
        }

        /// One crossing laid out: how far its gap reaches from the crossing along the strand underneath, the strand
        /// underneath's area and that area widened past the gap, and the strand on top with its gap either side.
        struct Site { let at: CGPoint; let reach: CGFloat; let underArea: CGPath; let refillArea: CGPath
                      let over: CGPath; let overBand: CGPath }
        let sites = knot.crossings.map { crossing -> Site in
            let reach = (w / 2 + g) / max(crossing.sine, 0.3) + w / 2
            let under = layout.piece(at: crossing.under, half: reach + w * 1.6)
            let over = layout.piece(at: crossing.over, half: reach + w)
            return Site(at: layout.place(crossing.point), reach: reach,
                        underArea: under.copy(strokingWithWidth: w + 2 * pixel, lineCap: .butt, lineJoin: .round, miterLimit: 4),
                        refillArea: under.copy(strokingWithWidth: w + 2 * g + 4 * pixel, lineCap: .butt, lineJoin: .round,
                                               miterLimit: 4),
                        over: over,
                        overBand: over.copy(strokingWithWidth: w + 2 * g, lineCap: .butt, lineJoin: .round, miterLimit: 4))
        }
        func disc(_ site: Site, _ radius: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: site.at.x - radius, y: site.at.y - radius, width: radius * 2, height: radius * 2),
                   transform: nil)
        }

        context.saveGState()
        if case .plain(let color) = paint { context.setAlpha(color.alpha) }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        fillPaint(clip: layout.line.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4))

        // 1. At each crossing, cut the strand underneath either side of the strand on top, only near the crossing.
        for site in sites {
            context.saveGState()
            context.addPath(disc(site, site.reach))
            context.clip()
            context.addPath(site.underArea)
            context.clip()
            context.setBlendMode(.clear)
            context.addPath(site.overBand)
            context.fillPath()
            context.restoreGState()
        }
        // 2. Paint the strand on top again where the cut touched it, across the strand underneath and a little either
        //    side, so the repaint's edge falls on line that was never cut and leaves no seam.
        for site in sites {
            context.saveGState()
            context.addPath(disc(site, site.reach + 2 * pixel))
            context.clip()
            context.addPath(site.refillArea)
            context.clip()
            fillPaint(clip: site.over.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .round, miterLimit: 4))
            context.restoreGState()
        }
        // 3. Lit, shade the strand underneath as it goes under, fading away from the gap. Last, so nothing paints
        //    over a shade, and never on the strand on top.
        let strength = shadeStrength(ink: side * (1 - 2 * inset) * zoom)
        if case .gradient = paint,
           let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [CGColor(srgbRed: 0.12, green: 0.04, blue: 0.22, alpha: strength),
                                           CGColor(srgbRed: 0.12, green: 0.04, blue: 0.22, alpha: 0)] as CFArray,
                                  locations: [0, 1]) {
            for site in sites {
                context.saveGState()
                context.addPath(site.underArea)
                context.clip()
                let outside = CGMutablePath()
                outside.addRect(rect.insetBy(dx: -side, dy: -side))
                outside.addPath(site.overBand)
                context.addPath(outside)
                context.clip(using: .evenOdd)
                context.setBlendMode(.sourceAtop)
                let inner = w / 2 + g
                context.drawRadialGradient(shade, startCenter: site.at, startRadius: inner, endCenter: site.at,
                                           endRadius: inner + w * 1.6, options: [.drawsBeforeStartLocation])
                context.restoreGState()
            }
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: For tests

    /// For each crossing in the square `rect`: the crossing itself, which is inked, and a point on the strand
    /// underneath just beside the strand on top, which is in the gap and clear.
    static func crossingsForTesting(in rect: CGRect) -> [(crossing: CGPoint, gap: CGPoint)] {
        let layout = Layout(ink: markRect(in: rect))
        let w = layout.weight, g = gap(weight: w)
        return knot.crossings.map { crossing in
            let along = (w / 2 + g / 2) / max(crossing.sine, 0.3) / layout.scale
            return (layout.place(crossing.point), layout.place(knot.point(at: crossing.under + along)))
        }
    }
}
#endif
