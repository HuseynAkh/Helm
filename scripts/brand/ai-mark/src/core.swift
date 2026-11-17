// Helm's AI mark, drawing core: one closed line that crosses itself, stroked in amber, coral and violet, with a small
// gap and a little shade where the line passes under itself. Pure CoreGraphics, no network, no image services.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Amber, coral and violet, from top to bottom: the colours of SparkMark.gradientColors.
let markColors: [CGColor] = [
    CGColor(srgbRed: 1.00, green: 0.71, blue: 0.20, alpha: 1),
    CGColor(srgbRed: 0.98, green: 0.44, blue: 0.38, alpha: 1),
    CGColor(srgbRed: 0.56, green: 0.36, blue: 0.96, alpha: 1)
]

/// How the line is painted: lit with the gradient (`turn` 0 to 1 turns its direction round the centre, as
/// SparkMark.drawGradient does for the shimmer), or in one plain colour, as the header's button draws it at rest.
enum Paint { case lit(turn: CGFloat); case plain(CGColor) }

/// Where the line crosses itself, as positions along the line (arc length in unit coordinates): the strand that
/// passes over, the strand that passes under, and the point itself.
struct Crossing { let point: CGPoint; let over: CGFloat; let under: CGFloat; let sine: CGFloat }

/// One option: its closed line in unit coordinates (centred, the larger half-extent is 1, y up) and how heavy the
/// line is drawn at each size.
struct Mark {
    let letter: String
    let name: String
    let points: [CGPoint]
    let lengths: [CGFloat]          // running arc length; lengths[i] is the start of segment i, the last is the total
    let crossings: [Crossing]
    let weightScale: CGFloat        // multiplies the shared stroke weight from 64 pt up
    let smallWeightScale: CGFloat   // multiplies it at 16 pt and below; sizes between are blended
    let gapScale: CGFloat           // multiplies the shared gap

    var total: CGFloat { lengths[lengths.count - 1] }

    init(letter: String, name: String, samples: Int = 1600, weightScale: CGFloat = 1, smallWeightScale: CGFloat? = nil,
         gapScale: CGFloat = 1, flip: Bool = false, rotate: CGFloat = 0, _ curve: (CGFloat) -> CGPoint) {
        self.letter = letter; self.name = name; self.weightScale = weightScale; self.gapScale = gapScale
        self.smallWeightScale = smallWeightScale ?? weightScale
        // Sample the curve over one turn, then centre it and scale it so the larger half-extent is 1.
        var raw = (0..<samples).map { i -> CGPoint in
            let p = curve(CGFloat(i) / CGFloat(samples) * 2 * .pi)
            return CGPoint(x: p.x * cos(rotate) - p.y * sin(rotate), y: p.x * sin(rotate) + p.y * cos(rotate))
        }
        let xs = raw.map(\.x), ys = raw.map(\.y)
        let cx = (xs.min()! + xs.max()!) / 2, cy = (ys.min()! + ys.max()!) / 2
        let half = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!) / 2
        raw = raw.map { CGPoint(x: ($0.x - cx) / half, y: ($0.y - cy) / half) }
        points = raw
        var running: [CGFloat] = [0]
        for i in raw.indices {
            let a = raw[i], b = raw[(i + 1) % raw.count]
            running.append(running[i] + hypot(b.x - a.x, b.y - a.y))
        }
        lengths = running
        crossings = Mark.findCrossings(raw, running, flip: flip)
    }

    /// Every place the line crosses itself, with over and under alternating along the line, as in a knot drawing.
    static func findCrossings(_ p: [CGPoint], _ len: [CGFloat], flip: Bool) -> [Crossing] {
        let n = p.count
        struct Hit { let point: CGPoint; let a: CGFloat; let b: CGFloat; let sine: CGFloat }
        var hits: [Hit] = []
        for i in 0..<n {
            let p1 = p[i], p2 = p[(i + 1) % n]
            let minX = min(p1.x, p2.x), maxX = max(p1.x, p2.x), minY = min(p1.y, p2.y), maxY = max(p1.y, p2.y)
            let r = CGVector(dx: p2.x - p1.x, dy: p2.y - p1.y)
            var j = i + 2
            while j < n {
                if i == 0 && j == n - 1 { j += 1; continue }
                let q1 = p[j], q2 = p[(j + 1) % n]
                if max(q1.x, q2.x) < minX || min(q1.x, q2.x) > maxX || max(q1.y, q2.y) < minY || min(q1.y, q2.y) > maxY {
                    j += 1; continue
                }
                let s = CGVector(dx: q2.x - q1.x, dy: q2.y - q1.y)
                let d = r.dx * s.dy - r.dy * s.dx
                if abs(d) > 1e-12 {
                    let qp = CGVector(dx: q1.x - p1.x, dy: q1.y - p1.y)
                    let t = (qp.dx * s.dy - qp.dy * s.dx) / d
                    let u = (qp.dx * r.dy - qp.dy * r.dx) / d
                    if t >= 0 && t < 1 && u >= 0 && u < 1 {
                        let sine = abs(d) / (hypot(r.dx, r.dy) * hypot(s.dx, s.dy))
                        hits.append(Hit(point: CGPoint(x: p1.x + r.dx * t, y: p1.y + r.dy * t),
                                        a: len[i] + (len[i + 1] - len[i]) * t, b: len[j] + (len[j + 1] - len[j]) * u, sine: sine))
                    }
                }
                j += 1
            }
        }
        // Over and under alternate along the line.
        var events: [(pos: CGFloat, hit: Int)] = []
        for (k, h) in hits.enumerated() { events.append((h.a, k)); events.append((h.b, k)) }
        events.sort { $0.pos < $1.pos }
        var overAt: [Int: CGFloat] = [:]
        var underAt: [Int: CGFloat] = [:]
        for (rank, e) in events.enumerated() {
            if (rank % 2 == 0) != flip { overAt[e.hit] = e.pos } else { underAt[e.hit] = e.pos }
        }
        var result: [Crossing] = []
        for (k, h) in hits.enumerated() {
            guard let o = overAt[k], let u = underAt[k] else {
                FileHandle.standardError.write(Data("crossing \(k) is not alternating\n".utf8)); continue
            }
            result.append(Crossing(point: h.point, over: o, under: u, sine: h.sine))
        }
        return result
    }

    /// The point at arc length `s`, wrapping round the closed line.
    func point(at s: CGFloat) -> CGPoint {
        var s = s.truncatingRemainder(dividingBy: total)
        if s < 0 { s += total }
        var lo = 0, hi = points.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if lengths[mid] <= s { lo = mid } else { hi = mid - 1 } }
        let a = points[lo], b = points[(lo + 1) % points.count]
        let segment = lengths[lo + 1] - lengths[lo]
        let t = segment > 0 ? (s - lengths[lo]) / segment : 0
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

// MARK: Weight

/// The stroke weight in points for a mark `size` points square: heavier for its size when small, so a 16 pt mark
/// still has a line about one and a half points wide, settling to 6.6 % of the size from 64 pt up.
func strokeWeight(size: CGFloat) -> CGFloat {
    let t = min(max((size - 16) / 48, 0), 1)
    return size * (0.090 - 0.024 * t)
}

/// The gap on each side of a strand where it passes over another, in points.
func gapWidth(size: CGFloat, weight: CGFloat) -> CGFloat {
    max(weight * 0.36, 0.5)
}

/// How dark the under strand gets right at the gap, fading out over about one and a half line widths.
let shadeStrength: CGFloat = 0.38

// MARK: Drawing

/// Draws `mark` in the square `rect` (in points; `pixel` is the size of one device pixel in points) with `paint`.
/// Everything happens inside one transparency layer, so the gaps are clear whatever is behind the mark.
func draw(_ mark: Mark, in rect: CGRect, context: CGContext, paint: Paint, pixel: CGFloat) {
    let size = min(rect.width, rect.height)
    let blend = min(max((size - 16) / 48, 0), 1)
    let w = strokeWeight(size: size) * (mark.smallWeightScale + (mark.weightScale - mark.smallWeightScale) * blend)
    let g = gapWidth(size: size, weight: w) * mark.gapScale
    let pad = size * 0.04
    let scale = size / 2 - pad - w / 2
    let center = CGPoint(x: rect.midX, y: rect.midY)
    func place(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + p.x * scale, y: center.y + p.y * scale) }

    let full = CGMutablePath()
    for (i, p) in mark.points.enumerated() { if i == 0 { full.move(to: place(p)) } else { full.addLine(to: place(p)) } }
    full.closeSubpath()

    /// A stretch of the line from `s - half` to `s + half` (arc length in points), as an open path.
    func piece(_ s: CGFloat, _ half: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let a = (s - half) / scale, b = (s + half) / scale
        let step = mark.total / CGFloat(mark.points.count) / 2
        var u = a
        path.move(to: place(mark.point(at: u)))
        while u < b { u = min(u + step, b); path.addLine(to: place(mark.point(at: u))) }
        return path
    }

    func fillPaint(clip: CGPath) {
        context.saveGState()
        context.addPath(clip)
        context.clip()
        switch paint {
        case .plain(let color):
            // Opaque inside the layer; the colour's own alpha is applied to the whole layer, so the strands put back
            // on top never come out darker than the rest.
            context.setFillColor(color.copy(alpha: 1) ?? color)
            context.fill(rect.insetBy(dx: -w, dy: -w))
        case .lit(let turn):
            let gradient = CGGradient(colorsSpace: sRGB, colors: markColors as CFArray, locations: [0, 0.5, 1])!
            let angle = turn * 2 * .pi
            let radius = size / 2 - pad
            let offset = CGVector(dx: sin(angle) * radius, dy: cos(angle) * radius)
            context.drawLinearGradient(gradient, start: CGPoint(x: center.x + offset.dx, y: center.y + offset.dy),
                                       end: CGPoint(x: center.x - offset.dx, y: center.y - offset.dy),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.restoreGState()
    }

    context.saveGState()
    if case .plain(let color) = paint { context.setAlpha(color.alpha) }
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    fillPaint(clip: full.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4))

    /// Where one crossing's work happens: the reach of its gap along the under strand, the two strands near it, the
    /// under strand's area and the over strand's band with its gap on either side.
    struct Site { let at: CGPoint; let reach: CGFloat; let underArea: CGPath; let refillArea: CGPath; let overBand: CGPath; let over: CGPath }
    let sites = mark.crossings.map { crossing -> Site in
        let sine = max(crossing.sine, 0.3)
        let reach = (w / 2 + g) / sine + w * 0.5
        let under = piece(crossing.under * scale, reach + w * 1.6)
        let over = piece(crossing.over * scale, reach + w)
        return Site(at: place(crossing.point), reach: reach,
                    underArea: under.copy(strokingWithWidth: w + 2 * pixel, lineCap: .butt, lineJoin: .round, miterLimit: 4),
                    refillArea: under.copy(strokingWithWidth: w + 2 * g + 4 * pixel, lineCap: .butt, lineJoin: .round, miterLimit: 4),
                    overBand: over.copy(strokingWithWidth: w + 2 * g, lineCap: .butt, lineJoin: .round, miterLimit: 4),
                    over: over)
    }
    func disc(_ site: Site, _ radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: site.at.x - radius, y: site.at.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    // 1. At every crossing, cut the under strand on both sides of the over strand, within a disc round the crossing so
    //    a cut never reaches another part of the line that happens to pass close by.
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

    // 2. Put each over strand back where its cut touched it: across the under strand and a little either side, so the
    //    edge of the repaint falls on untouched, fully painted line and leaves no seam.
    for site in sites {
        context.saveGState()
        context.addPath(disc(site, site.reach + 2 * pixel))
        context.clip()
        context.addPath(site.refillArea)
        context.clip()
        fillPaint(clip: site.over.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .round, miterLimit: 4))
        context.restoreGState()
    }

    // 3. Lit, shade each under strand where it goes under, fading away from the gap; last, so nothing paints over a
    //    shade, and never on that crossing's over strand.
    if case .lit = paint {
        let shade = CGGradient(colorsSpace: sRGB, colors: [CGColor(srgbRed: 0.12, green: 0.04, blue: 0.22, alpha: shadeStrength),
                                                           CGColor(srgbRed: 0.12, green: 0.04, blue: 0.22, alpha: 0)] as CFArray,
                               locations: [0, 1])!
        for site in sites {
            context.saveGState()
            context.addPath(site.underArea)
            context.clip()
            let outside = CGMutablePath()
            outside.addRect(rect.insetBy(dx: -size, dy: -size))
            outside.addPath(site.overBand)
            context.addPath(outside)
            context.clip(using: .evenOdd)
            context.setBlendMode(.sourceAtop)
            let inner = w / 2 + g
            context.drawRadialGradient(shade, startCenter: site.at, startRadius: inner, endCenter: site.at, endRadius: inner + w * 1.6,
                                       options: [.drawsBeforeStartLocation])
            context.restoreGState()
        }
    }
    context.endTransparencyLayer()
    context.restoreGState()
}

// MARK: Bitmaps

func makeContext(width: Int, height: Int) -> CGContext {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    return context
}

/// The mark alone, `size` points square at `scale` pixels per point, on a clear background.
func markImage(_ mark: Mark, size: CGFloat, scale: CGFloat, paint: Paint) -> CGImage {
    let px = Int((size * scale).rounded())
    let context = makeContext(width: px, height: px)
    context.scaleBy(x: scale, y: scale)
    draw(mark, in: CGRect(x: 0, y: 0, width: size, height: size), context: context, paint: paint, pixel: 1 / scale)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
    print("\(path): \(image.width)x\(image.height)")
}

func complex(_ a: CGFloat, _ k: CGFloat, _ t: CGFloat) -> CGPoint { CGPoint(x: a * cos(k * t), y: a * sin(k * t)) }
func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
