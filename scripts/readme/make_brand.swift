// Draws Helm's brand pictures in docs/brand: the mark of AI mode, the trefoil, and the README's banner in light and
// dark: the app icon, then the mark with "AI mode", the name and one line, as one lockup on a quiet field of the mark's
// colours. Everything is drawn here, with no image service and no network.
// usage: swift scripts/readme/make_brand.swift <app-icon.icns> <out-dir>
// The mark's line, weight, gaps, shade and colours are the ones Sources/HelmUI/Agent/SparkMark.swift draws in the app
// (the files keep the name spark, the mark it replaced). The icon is read from the app's own icon file and is never
// changed: it is only scaled.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make_brand.swift <app-icon.icns> <out-dir>\n".utf8))
    exit(2)
}
let iconURL = URL(fileURLWithPath: arguments[1])
let outDir = URL(fileURLWithPath: arguments[2], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// MARK: The mark, as SparkMark draws it

/// Amber, coral and violet, from top to bottom, as in SparkMark.gradientColors.
let sparkColors: [CGColor] = [
    CGColor(srgbRed: 1.00, green: 0.71, blue: 0.20, alpha: 1),
    CGColor(srgbRed: 0.98, green: 0.44, blue: 0.38, alpha: 1),
    CGColor(srgbRed: 0.56, green: 0.36, blue: 0.96, alpha: 1)
]

/// The knot's line, one loop at the top, sampled once, centred on its bounds and scaled so its larger half-extent
/// is 1. The same sums as SparkMark.Knot.
let knotPoints: [CGPoint] = {
    let samples = 1024
    var raw = (0..<samples).map { index -> CGPoint in
        let t = CGFloat(index) / CGFloat(samples) * 2 * .pi
        let x = cos(2 * t) + 0.6 * cos(-t) + 0.06 * cos(-4 * t)
        let y = sin(2 * t) + 0.6 * sin(-t) + 0.06 * sin(-4 * t)
        return CGPoint(x: -y, y: x)
    }
    let xs = raw.map(\.x), ys = raw.map(\.y)
    let half = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!) / 2
    let cx = (xs.min()! + xs.max()!) / 2, cy = (ys.min()! + ys.max()!) / 2
    raw = raw.map { CGPoint(x: ($0.x - cx) / half, y: ($0.y - cy) / half) }
    return raw
}()
let knotLengths: [CGFloat] = {
    var running: [CGFloat] = [0]
    for index in knotPoints.indices {
        let a = knotPoints[index], b = knotPoints[(index + 1) % knotPoints.count]
        running.append(running[index] + hypot(b.x - a.x, b.y - a.y))
    }
    return running
}()
let knotTotal = knotLengths[knotLengths.count - 1]

/// Where the line crosses itself, with over and under taking turns along the line.
struct Crossing { let point: CGPoint; let over: CGFloat; let under: CGFloat; let sine: CGFloat }
let knotCrossings: [Crossing] = {
    let p = knotPoints, count = p.count
    var hits: [(point: CGPoint, first: CGFloat, second: CGFloat, sine: CGFloat)] = []
    for i in 0..<count {
        let p1 = p[i], p2 = p[(i + 1) % count]
        let r = CGVector(dx: p2.x - p1.x, dy: p2.y - p1.y)
        for j in (i + 2)..<max(i + 2, count) where !(i == 0 && j == count - 1) {
            let q1 = p[j], q2 = p[(j + 1) % count]
            let s = CGVector(dx: q2.x - q1.x, dy: q2.y - q1.y)
            let cross = r.dx * s.dy - r.dy * s.dx
            guard abs(cross) > 1e-12 else { continue }
            let qp = CGVector(dx: q1.x - p1.x, dy: q1.y - p1.y)
            let t = (qp.dx * s.dy - qp.dy * s.dx) / cross, u = (qp.dx * r.dy - qp.dy * r.dx) / cross
            guard t >= 0, t < 1, u >= 0, u < 1 else { continue }
            hits.append((CGPoint(x: p1.x + r.dx * t, y: p1.y + r.dy * t), knotLengths[i] + (knotLengths[i + 1] - knotLengths[i]) * t,
                         knotLengths[j] + (knotLengths[j + 1] - knotLengths[j]) * u, abs(cross) / (hypot(r.dx, r.dy) * hypot(s.dx, s.dy))))
        }
    }
    var passes: [(at: CGFloat, hit: Int)] = []
    for (index, hit) in hits.enumerated() { passes += [(hit.first, index), (hit.second, index)] }
    passes.sort { $0.at < $1.at }
    var over: [Int: CGFloat] = [:], under: [Int: CGFloat] = [:]
    for (rank, pass) in passes.enumerated() { if rank % 2 == 0 { over[pass.hit] = pass.at } else { under[pass.hit] = pass.at } }
    return hits.indices.map { Crossing(point: hits[$0].point, over: over[$0]!, under: under[$0]!, sine: hits[$0].sine) }
}()

func knotPoint(at s: CGFloat) -> CGPoint {
    var s = s.truncatingRemainder(dividingBy: knotTotal)
    if s < 0 { s += knotTotal }
    var low = 0, high = knotPoints.count - 1
    while low < high { let middle = (low + high + 1) / 2; if knotLengths[middle] <= s { low = middle } else { high = middle - 1 } }
    let a = knotPoints[low], b = knotPoints[(low + 1) % knotPoints.count]
    let span = knotLengths[low + 1] - knotLengths[low]
    let t = span > 0 ? (s - knotLengths[low]) / span : 0
    return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

/// The mark laid out in its square, as SparkMark.draw lays it out: the ink 7 % in from each edge, the line's weight
/// and gap for that size, the whole line, and each crossing's cut and repaint.
struct MarkLayout {
    struct Site { let at: CGPoint; let reach: CGFloat; let underArea: CGPath; let refillArea: CGPath; let over: CGPath; let overBand: CGPath }
    let square: CGRect, weight: CGFloat, gap: CGFloat, line: CGPath, sites: [Site]

    init(square: CGRect, pixel: CGFloat) {
        self.square = square
        let ink = square.insetBy(dx: square.width * 0.07, dy: square.height * 0.07)
        let side = min(ink.width, ink.height)
        let w = 0.45 + 0.064 * side, g = max(w * 0.36, 0.5)
        weight = w; gap = g
        let center = CGPoint(x: ink.midX, y: ink.midY), scale = side / 2 - w / 2
        func place(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + p.x * scale, y: center.y + p.y * scale) }
        let line = CGMutablePath()
        for (index, point) in knotPoints.enumerated() { if index == 0 { line.move(to: place(point)) } else { line.addLine(to: place(point)) } }
        line.closeSubpath()
        self.line = line
        func piece(_ s: CGFloat, _ half: CGFloat) -> CGPath {
            let path = CGMutablePath()
            let end = s + half / scale, step = knotTotal / CGFloat(knotPoints.count) / 2
            var at = s - half / scale
            path.move(to: place(knotPoint(at: at)))
            while at < end { at = min(at + step, end); path.addLine(to: place(knotPoint(at: at))) }
            return path
        }
        sites = knotCrossings.map { crossing in
            let reach = (w / 2 + g) / max(crossing.sine, 0.3) + w / 2
            let under = piece(crossing.under, reach + w * 1.6), over = piece(crossing.over, reach + w)
            return Site(at: place(crossing.point), reach: reach,
                        underArea: under.copy(strokingWithWidth: w + 2 * pixel, lineCap: .butt, lineJoin: .round, miterLimit: 4),
                        refillArea: under.copy(strokingWithWidth: w + 2 * g + 4 * pixel, lineCap: .butt, lineJoin: .round, miterLimit: 4),
                        over: over, overBand: over.copy(strokingWithWidth: w + 2 * g, lineCap: .butt, lineJoin: .round, miterLimit: 4))
        }
    }

    func disc(_ site: Site, _ radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: site.at.x - radius, y: site.at.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    /// The mark's ink as one shape, gaps and all, for the SVG: the line, less each cut, with each strand on top
    /// put back.
    var ink: CGPath {
        var shape = line.copy(strokingWithWidth: weight, lineCap: .round, lineJoin: .round, miterLimit: 4)
        for site in sites { shape = shape.subtracting(disc(site, site.reach).intersection(site.underArea).intersection(site.overBand)) }
        for site in sites {
            let back = site.over.copy(strokingWithWidth: weight, lineCap: .butt, lineJoin: .round, miterLimit: 4)
            shape = shape.union(back.intersection(disc(site, site.reach + 0.5)).intersection(site.refillArea))
        }
        return shape
    }
}

/// The mark in its gradient, amber at the top to violet at the bottom, with its gaps and the shade where the line
/// goes under, in the square `rect`. `pixel` is one device pixel in the context's units.
func drawSpark(in rect: CGRect, context: CGContext, pixel: CGFloat = 1) {
    let layout = MarkLayout(square: rect, pixel: pixel)
    let w = layout.weight, g = layout.gap
    let gradient = CGGradient(colorsSpace: sRGB, colors: sparkColors as CFArray, locations: [0, 0.5, 1])!
    func paint(_ clip: CGPath) {
        context.saveGState()
        context.addPath(clip)
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }
    context.saveGState()
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    paint(layout.line.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4))
    for site in layout.sites {
        context.saveGState()
        context.addPath(layout.disc(site, site.reach)); context.clip()
        context.addPath(site.underArea); context.clip()
        context.setBlendMode(.clear)
        context.addPath(site.overBand); context.fillPath()
        context.restoreGState()
    }
    for site in layout.sites {
        context.saveGState()
        context.addPath(layout.disc(site, site.reach + 2 * pixel)); context.clip()
        context.addPath(site.refillArea); context.clip()
        paint(site.over.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .round, miterLimit: 4))
        context.restoreGState()
    }
    let strength = 0.38 * min(1, max(0.35, (min(rect.width, rect.height) * 0.86 - 4) / 26))
    let shade = CGGradient(colorsSpace: sRGB, colors: [CGColor(srgbRed: 0.12, green: 0.04, blue: 0.22, alpha: strength),
                                                       CGColor(srgbRed: 0.12, green: 0.04, blue: 0.22, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    for site in layout.sites {
        context.saveGState()
        context.addPath(site.underArea); context.clip()
        let outside = CGMutablePath()
        outside.addRect(rect.insetBy(dx: -rect.width, dy: -rect.height))
        outside.addPath(site.overBand)
        context.addPath(outside); context.clip(using: .evenOdd)
        context.setBlendMode(.sourceAtop)
        context.drawRadialGradient(shade, startCenter: site.at, startRadius: w / 2 + g, endCenter: site.at, endRadius: w / 2 + g + w * 1.6,
                                   options: [.drawsBeforeStartLocation])
        context.restoreGState()
    }
    context.endTransparencyLayer()
    context.restoreGState()
}

/// A soft wash of one colour, fading to nothing at `radius`, squashed to an ellipse by `squash`.
func drawWash(at center: CGPoint, radius: CGFloat, color: CGColor, squash: CGFloat, context: CGContext) {
    let gradient = CGGradient(colorsSpace: sRGB, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.scaleBy(x: 1, y: squash)
    context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
    context.restoreGState()
}

func makeContext(width: Int, height: Int) -> CGContext {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    return context
}

func writePNG(_ context: CGContext, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
    print("\(name): \(context.width)x\(context.height)")
}

// The mark alone, on a clear background.
do {
    let size = 1024
    let context = makeContext(width: size, height: size)
    drawSpark(in: CGRect(x: 0, y: 0, width: size, height: size), context: context)
    writePNG(context, "spark.png")
}

// The same mark as SVG, its ink written out as one shape with its gaps, so it stays sharp at any size. It's flat: the
// shade where the line goes under is left to the pictures.
do {
    let size: CGFloat = 256
    let layout = MarkLayout(square: CGRect(x: 0, y: 0, width: size, height: size), pixel: 0.25)
    // SVG counts y from the top, so every y is turned over.
    func spot(_ point: CGPoint) -> String { String(format: "%.2f %.2f", point.x, size - point.y) }
    var d = ""
    layout.ink.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: d += "M\(spot(points[0]))"
        case .addLineToPoint: d += "L\(spot(points[0]))"
        case .addQuadCurveToPoint: d += "Q\(spot(points[0])) \(spot(points[1]))"
        case .addCurveToPoint: d += "C\(spot(points[0])) \(spot(points[1])) \(spot(points[2]))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
      <defs>
        <linearGradient id="spark" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#FFB533"/>
          <stop offset="0.5" stop-color="#FA7061"/>
          <stop offset="1" stop-color="#8F5CF5"/>
        </linearGradient>
      </defs>
      <path d="\(d)" fill="url(#spark)"/>
    </svg>

    """
    do {
        try svg.write(to: outDir.appendingPathComponent("spark.svg"), atomically: true, encoding: .utf8)
        print("spark.svg")
    } catch {
        FileHandle.standardError.write(Data("can't write spark.svg\n".utf8)); exit(1)
    }
}

// MARK: The banner

guard let icon = NSImage(contentsOf: iconURL) else {
    FileHandle.standardError.write(Data("can't read \(iconURL.path)\n".utf8)); exit(1)
}
var iconRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
guard let iconImage = icon.cgImage(forProposedRect: &iconRect, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("no image in \(iconURL.path)\n".utf8)); exit(1)
}

/// One appearance of the banner: its field, the washes of the mark's colours over it, its type and its edge.
struct Look {
    let name: String
    let field: [UInt32]
    let washes: [(x: CGFloat, y: CGFloat, radius: CGFloat, color: CGColor, squash: CGFloat)]
    let eyebrow: NSColor, title: NSColor, line: NSColor
    let shadow: CGFloat, edge: CGColor
}
let looks = [
    // Light: a white field that warms a little towards the bottom, with pale tints of amber, coral and violet
    // drawn over white, so nothing mixes into grey.
    Look(name: "banner-light.png", field: [0xFFFFFF, 0xF8F6F3],
         washes: [(0.02, 1.02, 980, rgb(0xFFF0D4, 0.85), 0.62),
                  (0.70, -0.10, 900, rgb(0xFFE4DE, 0.80), 0.55),
                  (1.00, 0.70, 1000, rgb(0xEDE4FF, 0.95), 0.72)],
         eyebrow: NSColor(white: 0.16, alpha: 1), title: NSColor(white: 0.07, alpha: 1), line: NSColor(white: 0.40, alpha: 1),
         shadow: 0.24, edge: CGColor(gray: 0, alpha: 0.07)),
    // Dark: a deep neutral with only violet and a trace of coral, since amber over black turns brown.
    Look(name: "banner-dark.png", field: [0x131317, 0x09090B],
         washes: [(0.70, -0.10, 900, rgb(0xFA7061, 0.07), 0.55),
                  (1.00, 0.70, 1000, rgb(0x8F5CF5, 0.20), 0.72)],
         eyebrow: NSColor(white: 0.90, alpha: 1), title: NSColor(white: 0.97, alpha: 1), line: NSColor(white: 0.64, alpha: 1),
         shadow: 0.55, edge: CGColor(gray: 1, alpha: 0.12))
]

/// One line of SF Pro Display: the system font at these sizes.
func words(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, kern: CGFloat) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern])
}

// The lockup, centred: the unchanged icon, then one text column on a shared left edge. The mark leads the eyebrow,
// "AI mode", as it leads AI mode's lines in the app, sized to sit on the eyebrow's type; then the name and one line.
for look in looks {
    let width = 2400, height = 800
    let w = CGFloat(width), h = CGFloat(height)
    let context = makeContext(width: width, height: height)
    let card = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: 1, dy: 1), cornerWidth: 44, cornerHeight: 44, transform: nil)
    context.saveGState()
    context.addPath(card)
    context.clip()
    let field = CGGradient(colorsSpace: sRGB, colors: look.field.map { rgb($0) } as CFArray, locations: [0, 1])!
    context.drawLinearGradient(field, start: CGPoint(x: 0, y: h), end: .zero, options: [])
    for wash in look.washes {
        drawWash(at: CGPoint(x: w * wash.x, y: h * wash.y), radius: wash.radius, color: wash.color, squash: wash.squash, context: context)
    }

    let eyebrow = words("AI mode", size: 44, weight: .semibold, color: look.eyebrow, kern: -0.2)
    let title = words("Helm", size: 188, weight: .semibold, color: look.title, kern: -4.8)
    let line = words("An agentic file manager for your Mac.", size: 54, weight: .regular, color: look.line, kern: -0.4)
    let markSide: CGFloat = 62, markGap: CGFloat = 16
    let column = max(markSide + markGap + eyebrow.size().width, title.size().width, line.size().width)
    let iconSide: CGFloat = 380, gutter: CGFloat = 116
    let left = ((w - iconSide - gutter - column) / 2).rounded()
    let iconFrame = CGRect(x: left, y: (h - iconSide) / 2 + 2, width: iconSide, height: iconSide)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -16), blur: 46, color: CGColor(gray: 0, alpha: look.shadow))
    context.draw(iconImage, in: iconFrame)
    context.restoreGState()

    let textX = iconFrame.maxX + gutter
    let eyebrowY = h / 2 + 130
    drawSpark(in: CGRect(x: textX - 4, y: eyebrowY - 7, width: markSide, height: markSide), context: context)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    eyebrow.draw(at: CGPoint(x: textX + markSide + markGap - 4, y: eyebrowY + 2))
    // The name's H is set back by its side bearing, so its stem lines up with the mark and the line below.
    title.draw(at: CGPoint(x: textX - 12, y: h / 2 - 108))
    line.draw(at: CGPoint(x: textX - 2, y: h / 2 - 198))
    NSGraphicsContext.restoreGraphicsState()
    context.restoreGState()

    // A hairline edge round the card.
    context.addPath(card)
    context.setStrokeColor(look.edge)
    context.setLineWidth(2)
    context.strokePath()
    writePNG(context, look.name)
}
