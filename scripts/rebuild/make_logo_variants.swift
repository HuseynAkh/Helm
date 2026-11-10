// Draws five abstract logo alternatives for Helm, each in a different design style, plus an .icns for each
// and a contact sheet that shows every variant at 1024, 128 and 32 px.
// Usage: swift scripts/rebuild/make_logo_variants.swift <outdir>
//        swift scripts/rebuild/make_logo_variants.swift --app-icon
//   The second form, run from the repository root, makes variant 4 (Isometric) Helm's icon: App/AppIcon.icns for the
//   app and the PNGs of the legacy project's Helm/Helm/Resources/Assets.xcassets/AppIcon.appiconset.
// Writes into <outdir>: variant-N-<style>.png (1024 px), variant-N-<style>.icns and contact-sheet.png.
// Everything is drawn here in vectors with CoreGraphics, so each size is rendered sharp rather than scaled down.
// The tile follows the macOS icon grid: an 824 px continuous-corner square centred in the 1024 canvas.
import AppKit
import CoreImage

// MARK: - Colour, paths and drawing helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, alpha])!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// A drawing surface: a bitmap of `pixels` square, with the CTM set so that drawing code works in a
/// 1024-point canvas with the origin at the top left (y grows downwards).
final class Canvas {
    let ctx: CGContext
    let pixels: Int
    let scale: CGFloat

    init(pixels: Int) {
        self.pixels = pixels
        scale = CGFloat(pixels) / 1024
        ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: scale, y: -scale)
    }

    var image: CGImage { ctx.makeImage()! }

    func fill(_ path: CGPath, _ color: CGColor) {
        ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
    }

    /// Fills `path` with a linear gradient running from `a` to `b`.
    func fill(_ path: CGPath, _ g: CGGradient, from a: CGPoint, to b: CGPoint) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Paints a radial glow; the gradient's last colour should be transparent.
    func glow(_ g: CGGradient, at center: CGPoint, radius: CGFloat) {
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    /// Sets a shadow given in canvas units; CoreGraphics applies shadows in device pixels, with y pointing up.
    func shadow(dy: CGFloat, blur: CGFloat, _ color: CGColor, dx: CGFloat = 0) {
        ctx.setShadow(offset: CGSize(width: dx * scale, height: -dy * scale), blur: blur * scale, color: color)
    }

    /// Draws a full-canvas bitmap (for example a blurred copy of this canvas) aligned pixel for pixel.
    /// Any clip already set still applies.
    func drawPixels(_ image: CGImage, alpha: CGFloat = 1, blend: CGBlendMode = .normal) {
        ctx.saveGState()
        ctx.concatenate(ctx.ctm.inverted())
        ctx.setAlpha(alpha); ctx.setBlendMode(blend)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        ctx.restoreGState()
    }

    /// Renders `draw` into a separate transparent canvas of the same size and returns it as a bitmap.
    func layer(_ draw: (Canvas) -> Void) -> CGImage {
        let other = Canvas(pixels: pixels)
        draw(other)
        return other.image
    }
}

let ciContext = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])

/// A Gaussian blur of a full-canvas bitmap; `sigma` is in canvas units.
func blurred(_ image: CGImage, sigma: CGFloat, scale: CGFloat) -> CGImage {
    let input = CIImage(cgImage: image)
    let output = input.clampedToExtent().applyingGaussianBlur(sigma: Double(max(sigma * scale, 0.01))).cropped(to: input.extent)
    return ciContext.createCGImage(output, from: input.extent)!
}

/// A rounded rectangle with Apple's continuous ("squircle") corners, as used by the macOS icon grid.
func continuousRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    let k = min(radius, min(r.width, r.height) / 2 / 1.52866483)
    let (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
    let p = CGMutablePath()
    p.move(to: pt(x0 + 1.52866483 * k, y0))
    p.addLine(to: pt(x1 - 1.52866483 * k, y0))
    p.addCurve(to: pt(x1 - 0.63149399 * k, y0 + 0.07491139 * k), control1: pt(x1 - 1.08849323 * k, y0), control2: pt(x1 - 0.86840689 * k, y0))
    p.addCurve(to: pt(x1 - 0.07491139 * k, y0 + 0.63149399 * k), control1: pt(x1 - 0.37282392 * k, y0 + 0.16905380 * k), control2: pt(x1 - 0.16905380 * k, y0 + 0.37282392 * k))
    p.addCurve(to: pt(x1, y0 + 1.52866483 * k), control1: pt(x1, y0 + 0.86840689 * k), control2: pt(x1, y0 + 1.08849323 * k))
    p.addLine(to: pt(x1, y1 - 1.52866483 * k))
    p.addCurve(to: pt(x1 - 0.07491139 * k, y1 - 0.63149399 * k), control1: pt(x1, y1 - 1.08849323 * k), control2: pt(x1, y1 - 0.86840689 * k))
    p.addCurve(to: pt(x1 - 0.63149399 * k, y1 - 0.07491139 * k), control1: pt(x1 - 0.16905380 * k, y1 - 0.37282392 * k), control2: pt(x1 - 0.37282392 * k, y1 - 0.16905380 * k))
    p.addCurve(to: pt(x1 - 1.52866483 * k, y1), control1: pt(x1 - 0.86840689 * k, y1), control2: pt(x1 - 1.08849323 * k, y1))
    p.addLine(to: pt(x0 + 1.52866483 * k, y1))
    p.addCurve(to: pt(x0 + 0.63149399 * k, y1 - 0.07491139 * k), control1: pt(x0 + 1.08849323 * k, y1), control2: pt(x0 + 0.86840689 * k, y1))
    p.addCurve(to: pt(x0 + 0.07491139 * k, y1 - 0.63149399 * k), control1: pt(x0 + 0.37282392 * k, y1 - 0.16905380 * k), control2: pt(x0 + 0.16905380 * k, y1 - 0.37282392 * k))
    p.addCurve(to: pt(x0, y1 - 1.52866483 * k), control1: pt(x0, y1 - 0.86840689 * k), control2: pt(x0, y1 - 1.08849323 * k))
    p.addLine(to: pt(x0, y0 + 1.52866483 * k))
    p.addCurve(to: pt(x0 + 0.07491139 * k, y0 + 0.63149399 * k), control1: pt(x0, y0 + 1.08849323 * k), control2: pt(x0, y0 + 0.86840689 * k))
    p.addCurve(to: pt(x0 + 0.63149399 * k, y0 + 0.07491139 * k), control1: pt(x0 + 0.16905380 * k, y0 + 0.37282392 * k), control2: pt(x0 + 0.37282392 * k, y0 + 0.16905380 * k))
    p.addCurve(to: pt(x0 + 1.52866483 * k, y0), control1: pt(x0 + 0.86840689 * k, y0), control2: pt(x0 + 1.08849323 * k, y0))
    p.closeSubpath()
    return p
}

let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = continuousRect(tileRect, radius: 185)

/// Draws the tile with its drop shadow, then runs `paint` clipped to the tile.
func drawTile(_ c: Canvas, base: CGColor, shadowAlpha: CGFloat = 0.30, paint: (Canvas) -> Void) {
    c.ctx.saveGState()
    c.shadow(dy: 10, blur: 24, rgb(0x000000, shadowAlpha))
    c.fill(tilePath, base)
    c.ctx.restoreGState()
    c.ctx.saveGState()
    c.ctx.addPath(tilePath); c.ctx.clip()
    paint(c)
    c.ctx.restoreGState()
}

/// A hairline just inside the tile's edge, which keeps light or dark tiles crisp against any background.
func tileEdge(_ c: Canvas, _ color: CGColor, width: CGFloat = 3) {
    c.ctx.saveGState()
    c.ctx.addPath(tilePath); c.ctx.clip()
    c.ctx.addPath(tilePath); c.ctx.setStrokeColor(color); c.ctx.setLineWidth(width * 2); c.ctx.strokePath()
    c.ctx.restoreGState()
}

/// A quarter disc with its square corner at `corner`, sweeping a quarter turn from `start` radians.
func quarterDisc(corner: CGPoint, radius: CGFloat, start: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: corner)
    p.addRelativeArc(center: corner, radius: radius, startAngle: start, delta: .pi / 2)
    p.closeSubpath()
    return p
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
}

// MARK: - 1. Swiss / Bauhaus

/// A black H whose crossbar carries a red hub, with two primary-colour quarter discs turning around it like sails
/// (or the two halves of a wheel). Flat colour on a cream tile, in the manner of a Swiss poster.
func drawSwiss(_ c: Canvas) {
    drawTile(c, base: rgb(0xF2EBDD), shadowAlpha: 0.26) { c in
        let ink = rgb(0x171717)
        let stemWidth: CGFloat = 116, top: CGFloat = 252, bottom: CGFloat = 772
        let left = CGRect(x: 236, y: top, width: stemWidth, height: bottom - top)
        let right = CGRect(x: 788 - stemWidth, y: top, width: stemWidth, height: bottom - top)
        let sail: CGFloat = 168
        c.fill(quarterDisc(corner: pt(left.maxX, top), radius: sail, start: 0), rgb(0xF4B215))
        c.fill(quarterDisc(corner: pt(right.minX, bottom), radius: sail, start: .pi), rgb(0x1F56A8))
        c.fill(CGPath(rect: left, transform: nil), ink)
        c.fill(CGPath(rect: right, transform: nil), ink)
        c.fill(CGPath(rect: CGRect(x: left.maxX - 1, y: 476, width: right.minX - left.maxX + 2, height: 72), transform: nil), ink)
        c.fill(circle(pt(512, 512), 100), rgb(0xE13A2C))
    }
    tileEdge(c, rgb(0x000000, 0.06), width: 2)
}

// MARK: - 2. Glass

/// A folder silhouette centred on the origin: a rounded body with a tab rising from its top-left.
func folderShape(width w: CGFloat, height h: CGFloat, radius r: CGFloat, tabWidth tw: CGFloat, tabHeight th: CGFloat) -> CGMutablePath {
    let x0 = -w / 2, x1 = w / 2, y0 = -h / 2, y1 = h / 2
    let p = CGMutablePath()
    p.move(to: pt(x0, y1 - r))
    p.addArc(tangent1End: pt(x0, y0 - th), tangent2End: pt(x0 + tw, y0 - th), radius: r * 0.6)
    p.addArc(tangent1End: pt(x0 + tw, y0 - th), tangent2End: pt(x0 + tw + th, y0), radius: th * 0.6)
    p.addArc(tangent1End: pt(x0 + tw + th, y0), tangent2End: pt(x1, y0), radius: th * 0.6)
    p.addArc(tangent1End: pt(x1, y0), tangent2End: pt(x1, y1), radius: r)
    p.addArc(tangent1End: pt(x1, y1), tangent2End: pt(x0, y1), radius: r)
    p.addArc(tangent1End: pt(x0, y1), tangent2End: pt(x0, y0), radius: r)
    p.closeSubpath()
    return p
}

/// One pane of frosted glass: it casts a soft shadow, blurs whatever is behind it, takes a tint, shows a little
/// thickness along its lower edge, and catches light on its rim. `top` and `bottom` give the direction of the light.
func glassPane(_ c: Canvas, _ path: CGPath, tint: UInt32, top: CGPoint, bottom: CGPoint, strength s: CGFloat) {
    let behind = blurred(c.image, sigma: 18, scale: c.scale)
    let ctx = c.ctx
    let along: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    ctx.saveGState()
    c.shadow(dy: 24, blur: 48, rgb(0x0A0730, 0.42))
    c.fill(path, rgb(tint, 0.5))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    c.drawPixels(behind)
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.58 * s), rgb(tint, 0.36 * s), rgb(tint, 0.28 * s)], [0, 0.55, 1]),
                           start: top, end: bottom, options: along)
    c.glow(gradient([rgb(0xFFFFFF, 0.30 * s), rgb(0xFFFFFF, 0)]), at: pt(top.x * 0.75 + bottom.x * 0.25, top.y * 0.75 + bottom.y * 0.25),
           radius: 240)
    // Thickness: a deeper tint inside the lower edge.
    ctx.addPath(path); ctx.setLineWidth(26); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(tint, 0), rgb(0x1B0F6B, 0.30)], [0.55, 1]), start: top, end: bottom, options: along)
    ctx.restoreGState()

    // Rim, drawn just inside the edge: bright where it faces the light, fading towards the bottom.
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.addPath(path); ctx.setLineWidth(7); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.95), rgb(0xFFFFFF, 0.40), rgb(0xFFFFFF, 0.18)], [0, 0.5, 1]),
                           start: top, end: bottom, options: along)
    ctx.restoreGState()
}

/// An H of three frosted panes: two upright panes, and a crossbar shaped like a folder laid across them.
func drawGlass(_ c: Canvas) {
    drawTile(c, base: rgb(0x2B2FC8)) { c in
        c.fill(tilePath, gradient([rgb(0x3A72F8), rgb(0x2B2FC8), rgb(0x1A0F6E)], [0, 0.5, 1]), from: pt(240, 110), to: pt(780, 930))
        c.glow(gradient([rgb(0x5CF0FF, 0.40), rgb(0x5CF0FF, 0)]), at: pt(190, 150), radius: 480)
        c.glow(gradient([rgb(0xFF4FC3, 0.60), rgb(0xFF4FC3, 0)]), at: pt(880, 900), radius: 600)

        let stemTop: CGFloat = 244, stemBottom: CGFloat = 780, stemWidth: CGFloat = 150
        let left = CGRect(x: 238, y: stemTop, width: stemWidth, height: stemBottom - stemTop)
        let right = CGRect(x: 786 - stemWidth, y: stemTop, width: stemWidth, height: stemBottom - stemTop)
        glassPane(c, continuousRect(left, radius: 74), tint: 0x55E6FF, top: pt(left.minX, left.minY), bottom: pt(left.maxX, left.maxY), strength: 1.3)
        glassPane(c, continuousRect(right, radius: 74), tint: 0xFF7BE0, top: pt(right.minX, right.minY), bottom: pt(right.maxX, right.maxY), strength: 1.3)
        var place = CGAffineTransform(translationX: 512, y: 540)
        let bar = folderShape(width: 470, height: 150, radius: 52, tabWidth: 160, tabHeight: 44).copy(using: &place)!
        glassPane(c, bar, tint: 0xFFFFFF, top: pt(512, 421), bottom: pt(512, 615), strength: 1.5)
    }
    tileEdge(c, rgb(0xFFFFFF, 0.16), width: 2)
}

// MARK: - 3. Monoline

/// One even-weight line that never lifts: a folder whose tab's sloping edge runs straight on into a compass needle.
func drawMonoline(_ c: Canvas) {
    let x0: CGFloat = 232, x1: CGFloat = 792, y0: CGFloat = 366, y1: CGFloat = 738, corner: CGFloat = 64
    let tabTop: CGFloat = 292
    let tip = pt(512, y0), half = (y1 - y0) / 2, width: CGFloat = 76
    let tabEnd = tip.x - width / half * (y0 - tabTop) // same slope as the needle's side
    let line = CGMutablePath()
    line.move(to: pt(x0, y1 - corner))
    line.addArc(tangent1End: pt(x0, tabTop), tangent2End: pt(tabEnd, tabTop), radius: 40)
    line.addArc(tangent1End: pt(tabEnd, tabTop), tangent2End: tip, radius: 18)
    line.addLine(to: pt(tip.x + width, y0 + half))
    line.addLine(to: pt(tip.x, y1))
    line.addLine(to: pt(tip.x - width, y0 + half))
    line.addLine(to: tip)
    line.addArc(tangent1End: pt(x1, y0), tangent2End: pt(x1, y1), radius: corner)
    line.addArc(tangent1End: pt(x1, y1), tangent2End: pt(x0, y1), radius: corner)
    line.addArc(tangent1End: pt(x0, y1), tangent2End: pt(x0, y0), radius: corner)
    line.closeSubpath()
    // A heavier line at small sizes keeps it from fading to a hairline.
    let weight: CGFloat = c.pixels <= 16 ? 76 : c.pixels <= 32 ? 60 : c.pixels <= 64 ? 50 : 40

    drawTile(c, base: rgb(0x10284A)) { c in
        c.fill(tilePath, gradient([rgb(0x1A3F66), rgb(0x0C1E3A), rgb(0x081428)], [0, 0.6, 1]), from: pt(512, 100), to: pt(512, 924))
        c.glow(gradient([rgb(0x5FA8FF, 0.18), rgb(0x5FA8FF, 0)]), at: pt(512, 240), radius: 520)
        c.ctx.saveGState()
        c.ctx.addPath(line); c.ctx.setLineWidth(weight); c.ctx.setLineJoin(.round); c.ctx.setLineCap(.round)
        c.ctx.replacePathWithStrokedPath(); c.ctx.clip()
        c.ctx.drawLinearGradient(gradient([rgb(0xFFE7B0), rgb(0xF4B860)]), start: pt(x0, tabTop), end: pt(x1, y1),
                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.ctx.restoreGState()
    }
    tileEdge(c, rgb(0xFFFFFF, 0.10), width: 2)
}

// MARK: - 4. Isometric

struct IsoBox {
    var x: CGFloat, y: CGFloat, z: CGFloat, w: CGFloat, d: CGFloat, h: CGFloat
    var top: UInt32, left: UInt32, right: UInt32
}

/// Three slabs stacked in isometric projection, the middle one pulled out like a drawer, each in three tones.
func drawIsometric(_ c: Canvas) {
    drawTile(c, base: rgb(0x1E2742)) { c in
        c.fill(tilePath, gradient([rgb(0x2B3760), rgb(0x161D33)]), from: pt(512, 100), to: pt(512, 924))
        c.glow(gradient([rgb(0x8FB4FF, 0.16), rgb(0x8FB4FF, 0)]), at: pt(512, 420), radius: 460)

        let size: CGFloat = 300, thick: CGFloat = 70, gap: CGFloat = 26, pull: CGFloat = 78
        let boxes = [
            IsoBox(x: 0, y: 0, z: 0, w: size, d: size, h: thick, top: 0x6F8BFF, left: 0x4A63DE, right: 0x3242A8),
            IsoBox(x: pull, y: 0, z: thick + gap, w: size, d: size, h: thick, top: 0xFFD27A, left: 0xF4A52A, right: 0xC27612),
            IsoBox(x: 0, y: 0, z: 2 * (thick + gap), w: size, d: size, h: thick, top: 0xB4E6FF, left: 0x7CC3F2, right: 0x4F93C9),
        ]
        let cos30: CGFloat = 0.8660254
        func project(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint { pt((x - y) * cos30, (x + y) * 0.5 - z) }
        // Centre the stack's bounding box in the tile.
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for b in boxes {
            for (x, y, z) in [(b.x, b.y, b.z + b.h), (b.x + b.w, b.y, b.z), (b.x + b.w, b.y + b.d, b.z), (b.x, b.y + b.d, b.z),
                              (b.x, b.y + b.d, b.z + b.h)] {
                let p = project(x, y, z)
                minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        let offset = pt(512 - (minX + maxX) / 2, 512 - (minY + maxY) / 2 - 8)
        func iso(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
            let p = project(x, y, z); return pt(p.x + offset.x, p.y + offset.y)
        }
        func polygon(_ points: [CGPoint]) -> CGPath {
            let p = CGMutablePath(); p.addLines(between: points); p.closeSubpath(); return p
        }
        // A soft shadow on the ground under the stack.
        let ground = c.layer { layer in
            var drop = CGAffineTransform(translationX: 0, y: 30)
            let footprint = polygon([iso(-12, -12, 0), iso(size + pull + 12, -12, 0), iso(size + pull + 12, size + 12, 0), iso(-12, size + 12, 0)])
            layer.fill(footprint.copy(using: &drop)!, rgb(0x000000, 0.55))
        }
        c.drawPixels(blurred(ground, sigma: 24, scale: c.scale))
        for b in boxes {
            let (x0, y0, z0, x1, y1, z1) = (b.x, b.y, b.z, b.x + b.w, b.y + b.d, b.z + b.h)
            let top = polygon([iso(x0, y0, z1), iso(x1, y0, z1), iso(x1, y1, z1), iso(x0, y1, z1)])
            let left = polygon([iso(x0, y1, z1), iso(x1, y1, z1), iso(x1, y1, z0), iso(x0, y1, z0)])
            let right = polygon([iso(x1, y0, z1), iso(x1, y1, z1), iso(x1, y1, z0), iso(x1, y0, z0)])
            c.fill(left, rgb(b.left)); c.fill(right, rgb(b.right)); c.fill(top, rgb(b.top))
            // A lit front edge keeps the planes crisp.
            let edge = CGMutablePath(); edge.addLines(between: [iso(x0, y1, z1), iso(x1, y1, z1), iso(x1, y0, z1)])
            c.ctx.addPath(edge); c.ctx.setStrokeColor(rgb(0xFFFFFF, 0.5)); c.ctx.setLineWidth(3); c.ctx.setLineJoin(.round); c.ctx.strokePath()
        }
        // The drawer's handle, on its front face.
        let drawer = boxes[1]
        let midY = drawer.y + drawer.d / 2, midZ = drawer.z + drawer.h / 2
        let handle = CGMutablePath()
        handle.move(to: iso(drawer.x + drawer.w, midY - 50, midZ)); handle.addLine(to: iso(drawer.x + drawer.w, midY + 50, midZ))
        c.ctx.addPath(handle); c.ctx.setStrokeColor(rgb(0x6B3B05, 0.85)); c.ctx.setLineWidth(17); c.ctx.setLineCap(.round); c.ctx.strokePath()
    }
    tileEdge(c, rgb(0xFFFFFF, 0.10), width: 2)
}

// MARK: - 5. Op-art neon

/// An eight-spoke helm reduced to rhythm: three neon rings broken by eight spokes of darkness, each ring turned a
/// little further than the one inside it, so the wheel seems to turn. Near-black tile.
func drawNeon(_ c: Canvas) {
    drawTile(c, base: rgb(0x0B0A12)) { c in
        c.fill(tilePath, gradient([rgb(0x161325), rgb(0x07060C)]), from: pt(512, 100), to: pt(512, 924))
        let center = pt(512, 512)
        // At 32 px and below three rings blur into a mosaic, so the small sizes keep only the outer ring, drawn heavier.
        let small = c.pixels <= 32
        let rings: [(radius: CGFloat, width: CGFloat)] = small ? [(300, 96)] : [(162, 38), (238, 42), (318, 46)]
        let gapPx: CGFloat = small ? 56 : 30, turn: CGFloat = 10 * .pi / 180
        let hub: CGFloat = small ? 100 : 48, glow: CGFloat = small ? 0.7 : 1
        func tubes(widthScale: CGFloat) -> CGPath {
            let p = CGMutablePath()
            for (index, ring) in rings.enumerated() {
                let gap = (gapPx + ring.width) / ring.radius // round caps eat into the gap, so widen it by one tube width
                for k in 0..<8 {
                    let arc = CGMutablePath()
                    arc.addRelativeArc(center: center, radius: ring.radius,
                                       startAngle: CGFloat(k) * .pi / 4 - .pi / 8 + gap / 2 + CGFloat(index) * turn, delta: .pi / 4 - gap)
                    p.addPath(arc.copy(strokingWithWidth: ring.width * widthScale, lineCap: .round, lineJoin: .round, miterLimit: 10))
                }
            }
            return p
        }
        // Pink at the top, through violet and blue, to ice cyan at the bottom (and back up the other side).
        let spectrum = gradient([rgb(0xFF3D9A), rgb(0xB44BFF), rgb(0x3D7BFF), rgb(0x22E1FF), rgb(0x3D7BFF), rgb(0xB44BFF), rgb(0xFF3D9A)],
                                [0, 0.17, 0.33, 0.5, 0.67, 0.83, 1])
        let neon = c.layer { layer in
            layer.ctx.saveGState(); layer.ctx.addPath(tubes(widthScale: 1)); layer.ctx.clip()
            if #available(macOS 14.0, *) {
                CGContextDrawConicGradient(layer.ctx, spectrum, center, -.pi / 2)
            } else {
                layer.ctx.drawLinearGradient(spectrum, start: pt(512, 190), end: pt(512, 1474), options: [])
            }
            layer.ctx.restoreGState()
            layer.fill(circle(center, hub), rgb(0xFFFFFF))
        }
        c.drawPixels(blurred(neon, sigma: 34, scale: c.scale), alpha: 0.9 * glow, blend: .plusLighter)
        c.drawPixels(blurred(neon, sigma: 10, scale: c.scale), alpha: 0.8 * glow, blend: .plusLighter)
        c.drawPixels(neon)
        // A hot white core along each tube.
        c.fill(tubes(widthScale: 0.32), rgb(0xFFFFFF, 0.55))
        c.glow(gradient([rgb(0xFFFFFF), rgb(0xFFE6F4, 0.9), rgb(0xFF7AC8, 0)], [0, 0.6, 1]), at: center, radius: hub + 8)
    }
    tileEdge(c, rgb(0xFFFFFF, 0.08), width: 2)
}

// MARK: - Variants, icon sets and the contact sheet

struct Variant {
    let number: Int, slug: String, title: String, idea: String
    let draw: (Canvas) -> Void
    var name: String { "variant-\(number)-\(slug)" }
}

let variants = [
    Variant(number: 1, slug: "swiss", title: "Swiss / Bauhaus", idea: "An H with a hub and two turning sails", draw: drawSwiss),
    Variant(number: 2, slug: "glass", title: "Glass", idea: "Frosted panes form an H; the crossbar is a folder", draw: drawGlass),
    Variant(number: 3, slug: "monoline", title: "Monoline", idea: "One line: the folder tab runs into a compass needle", draw: drawMonoline),
    Variant(number: 4, slug: "isometric", title: "Isometric", idea: "A stack of slabs with one drawer out", draw: drawIsometric),
    Variant(number: 5, slug: "neon", title: "Op-art neon", idea: "An eight-spoke helm reduced to rhythm", draw: drawNeon),
]

func render(_ variant: Variant, pixels: Int) -> CGImage {
    let canvas = Canvas(pixels: pixels)
    variant.draw(canvas)
    return canvas.image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make_logo_variants", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed for \(url.path)"])
    }
    try data.write(to: url)
}

func makeIcns(_ variant: Variant, into outdir: URL, scratch: URL) throws {
    let iconset = scratch.appendingPathComponent("\(variant.name).iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let file = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try writePNG(render(variant, pixels: points * factor), to: iconset.appendingPathComponent(file))
        }
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", outdir.appendingPathComponent("\(variant.name).icns").path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw NSError(domain: "make_logo_variants", code: 2, userInfo: [NSLocalizedDescriptionKey: "iconutil failed for \(variant.name)"])
    }
}

/// All five side by side: each at 360 px, then at 128 px and 32 px (on light and on dark), each size rendered natively.
func makeContactSheet() -> CGImage {
    let column: CGFloat = 440, margin: CGFloat = 50, headerHeight: CGFloat = 96
    let width = Int(margin * 2 + column * CGFloat(variants.count)), height = 730
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(rgb(0xF3F3F5)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    func place(_ image: CGImage, at origin: CGPoint) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: origin.x, y: origin.y + CGFloat(image.height)); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.restoreGState()
    }
    func text(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor,
              alignment: NSTextAlignment = .center) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment
        (string as NSString).draw(in: CGRect(x: x, y: y, width: width, height: size * 1.6),
                                  withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
                                                   .paragraphStyle: paragraph])
        NSGraphicsContext.restoreGraphicsState()
    }

    text("Helm — abstract logo variants", x: margin + 20, y: 30, width: 900, size: 30, weight: .bold, color: NSColor(white: 0.1, alpha: 1),
         alignment: .left)
    text("Each column: 360 px, then 128 px and 32 px on light and dark, every size drawn natively.", x: margin + 20, y: 66, width: 1200,
         size: 15, weight: .regular, color: NSColor(white: 0.4, alpha: 1), alignment: .left)
    for (index, variant) in variants.enumerated() {
        let x0 = margin + CGFloat(index) * column
        place(render(variant, pixels: 360), at: pt(x0 + (column - 360) / 2, headerHeight + 10))
        let rowY = headerHeight + 10 + 360 + 18
        let small128 = render(variant, pixels: 128), small32 = render(variant, pixels: 32)
        let rowWidth: CGFloat = 128 + 24 + 56 + 12 + 56
        let rx = x0 + (column - rowWidth) / 2
        place(small128, at: pt(rx, rowY))
        let lightChip = CGRect(x: rx + 128 + 24, y: rowY + 36, width: 56, height: 56)
        let darkChip = CGRect(x: lightChip.maxX + 12, y: rowY + 36, width: 56, height: 56)
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.addPath(CGPath(roundedRect: lightChip, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
        ctx.setFillColor(rgb(0x1E1E22)); ctx.addPath(CGPath(roundedRect: darkChip, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
        place(small32, at: pt(lightChip.minX + 12, lightChip.minY + 12))
        place(small32, at: pt(darkChip.minX + 12, darkChip.minY + 12))
        text("\(variant.number)  \(variant.title)", x: x0, y: rowY + 128 + 26, width: column, size: 22, weight: .semibold,
             color: NSColor(white: 0.1, alpha: 1))
        text(variant.idea, x: x0, y: rowY + 128 + 60, width: column, size: 15, weight: .regular, color: NSColor(white: 0.38, alpha: 1))
    }
    return ctx.makeImage()!
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { print("usage: make_logo_variants.swift <outdir> | --app-icon"); exit(2) }

/// Helm's own icon is variant 4, Isometric, chosen by Huseyn on 2026-11-08.
let appIconVariant = variants[3]

if arguments[1] == "--app-icon" {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let app = root.appendingPathComponent("App")
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("helm-app-icon-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    try makeIcns(appIconVariant, into: scratch, scratch: scratch)
    let icns = app.appendingPathComponent("AppIcon.icns")
    try? FileManager.default.removeItem(at: icns)
    try FileManager.default.moveItem(at: scratch.appendingPathComponent("\(appIconVariant.name).icns"), to: icns)
    // The legacy project's asset catalog: one PNG per slot, named in its Contents.json.
    let set = root.appendingPathComponent("Helm/Helm/Resources/Assets.xcassets/AppIcon.appiconset")
    var images: [[String: String]] = []
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let file = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
            try writePNG(render(appIconVariant, pixels: points * factor), to: set.appendingPathComponent(file))
            images.append(["filename": file, "idiom": "mac", "scale": "\(factor)x", "size": "\(points)x\(points)"])
        }
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: set.appendingPathComponent("Contents.json"))
    try? FileManager.default.removeItem(at: scratch)
    print("wrote App/AppIcon.icns and the legacy AppIcon.appiconset from \(appIconVariant.name)")
    exit(0)
}
let outdir = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("helm-logo-variants-\(UUID().uuidString)")
for variant in variants {
    try writePNG(render(variant, pixels: 1024), to: outdir.appendingPathComponent("\(variant.name).png"))
    try makeIcns(variant, into: outdir, scratch: scratch)
    print("wrote \(variant.name).png and .icns")
}
try writePNG(makeContactSheet(), to: outdir.appendingPathComponent("contact-sheet.png"))
try? FileManager.default.removeItem(at: scratch)
print("wrote contact-sheet.png in \(outdir.path)")
