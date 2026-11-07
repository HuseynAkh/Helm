// Draws Helm's app icon: a small horned Norse helmet sitting on a folder, on a rounded-square tile.
// Usage: swift scripts/rebuild/make_app_icon.swift <output.iconset> [preview.png]
// Then: iconutil -c icns <output.iconset> -o App/AppIcon.icns
// Everything is drawn here in vectors, so each size is rendered sharp rather than scaled down.
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// All coordinates are in a 1024-point canvas with the origin at the top left.
func drawIcon() {
    // MARK: Tile
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = color(0x000000, 0.32)
    tileShadow.shadowBlurRadius = 24
    tileShadow.shadowOffset = NSSize(width: 0, height: -10) // Shadow offsets ignore the flipped canvas.
    tileShadow.set()
    color(0x1B3558).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x3F78B5), color(0x234A7A), color(0x152B4A)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: tile, angle: 90)
    // A soft light from the top, like northern sky.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [color(0x9FD3FF, 0.30), color(0x9FD3FF, 0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 150), radius: 0, toCenter: NSPoint(x: 512, y: 150), radius: 560, options: [])
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, 0.10).setStroke(); tile.lineWidth = 3
    NSBezierPath(roundedRect: NSRect(x: 101.5, y: 101.5, width: 821, height: 821), xRadius: 185, yRadius: 185).stroke()

    // MARK: Folder
    let back = NSBezierPath()
    back.move(to: NSPoint(x: 210, y: 420))
    back.line(to: NSPoint(x: 210, y: 384))
    back.curve(to: NSPoint(x: 250, y: 344), controlPoint1: NSPoint(x: 210, y: 362), controlPoint2: NSPoint(x: 228, y: 344))
    back.line(to: NSPoint(x: 410, y: 344))
    back.curve(to: NSPoint(x: 446, y: 362), controlPoint1: NSPoint(x: 426, y: 344), controlPoint2: NSPoint(x: 436, y: 350))
    back.line(to: NSPoint(x: 470, y: 392))
    back.line(to: NSPoint(x: 774, y: 392))
    back.curve(to: NSPoint(x: 814, y: 432), controlPoint1: NSPoint(x: 796, y: 392), controlPoint2: NSPoint(x: 814, y: 410))
    back.line(to: NSPoint(x: 814, y: 760))
    back.line(to: NSPoint(x: 210, y: 760))
    back.close()
    NSGradient(colors: [color(0x3A86D9), color(0x2563B0)])!.draw(in: back, angle: 90)

    let paper = NSBezierPath(roundedRect: NSRect(x: 236, y: 410, width: 552, height: 120), xRadius: 14, yRadius: 14)
    color(0xF4F1EA).setFill(); paper.fill()

    let front = NSBezierPath(roundedRect: NSRect(x: 200, y: 452, width: 624, height: 370), xRadius: 36, yRadius: 36)
    NSGraphicsContext.saveGraphicsState()
    let frontShadow = NSShadow()
    frontShadow.shadowColor = color(0x0B1A30, 0.35); frontShadow.shadowBlurRadius = 18
    frontShadow.shadowOffset = NSSize(width: 0, height: -4)
    frontShadow.set()
    color(0x62A8F2).setFill(); front.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x8CC4FF), color(0x5A9EEA), color(0x3F86D6)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(in: front, angle: 90)
    // A bright top lip on the front flap.
    NSGraphicsContext.saveGraphicsState()
    front.addClip()
    color(0xFFFFFF, 0.35).setFill()
    NSBezierPath(rect: NSRect(x: 200, y: 452, width: 624, height: 6)).fill()
    NSGraphicsContext.restoreGraphicsState()

    // MARK: Helmet
    // Contact shadow where the helmet sits on the folder.
    NSGraphicsContext.saveGraphicsState()
    front.addClip()
    NSGradient(colors: [color(0x0B1A30, 0.28), color(0x0B1A30, 0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 462), radius: 0, toCenter: NSPoint(x: 512, y: 462), radius: 150, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // A mini helmet: drawn full size, then scaled down around the point where it sits on the folder's lip.
    NSGraphicsContext.saveGraphicsState()
    let seat = NSAffineTransform()
    seat.translateX(by: 512, yBy: 466); seat.scale(by: helmetScale); seat.translateX(by: -512, yBy: -466)
    seat.concat()
    drawHorn(mirrored: false)
    drawHorn(mirrored: true)

    // Dome.
    let dome = NSBezierPath()
    dome.move(to: NSPoint(x: 362, y: 468))
    dome.curve(to: NSPoint(x: 512, y: 232), controlPoint1: NSPoint(x: 356, y: 330), controlPoint2: NSPoint(x: 420, y: 232))
    dome.curve(to: NSPoint(x: 662, y: 468), controlPoint1: NSPoint(x: 604, y: 232), controlPoint2: NSPoint(x: 668, y: 330))
    dome.close()
    NSGradient(colors: [color(0xF2F5F8), color(0xB9C3CE), color(0x7D8A99)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: dome, angle: 90)
    // Side shading so it reads as round.
    NSGraphicsContext.saveGraphicsState()
    dome.addClip()
    NSGradient(colors: [color(0x2C3642, 0.35), color(0x2C3642, 0), color(0x2C3642, 0), color(0x2C3642, 0.45)],
               atLocations: [0, 0.3, 0.62, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: 362, y: 232, width: 300, height: 240), angle: 0)
    // A sharp highlight on the upper left.
    let shine = NSBezierPath(ovalIn: NSRect(x: 420, y: 268, width: 70, height: 120))
    let rotate = AffineTransform(rotationByDegrees: -24)
    var around = AffineTransform(translationByX: -455, byY: -328)
    around.append(rotate); around.append(AffineTransform(translationByX: 455, byY: 328))
    shine.transform(using: around)
    color(0xFFFFFF, 0.55).setFill(); shine.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0x46525F).setStroke(); dome.lineWidth = 6; dome.stroke()

    // Bronze crest running over the top.
    let crest = NSBezierPath()
    crest.move(to: NSPoint(x: 490, y: 238))
    crest.curve(to: NSPoint(x: 534, y: 238), controlPoint1: NSPoint(x: 500, y: 232), controlPoint2: NSPoint(x: 524, y: 232))
    crest.line(to: NSPoint(x: 536, y: 450))
    crest.line(to: NSPoint(x: 488, y: 450))
    crest.close()
    NSGradient(colors: [color(0xF6D27A), color(0xC98B2E), color(0x8F5B17)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: crest, angle: 0)
    color(0x6B4210).setStroke(); crest.lineWidth = 4; crest.stroke()

    // Nose guard.
    let nasal = NSBezierPath()
    nasal.move(to: NSPoint(x: 492, y: 480))
    nasal.line(to: NSPoint(x: 532, y: 480))
    nasal.line(to: NSPoint(x: 526, y: 588))
    nasal.curve(to: NSPoint(x: 498, y: 588), controlPoint1: NSPoint(x: 520, y: 600), controlPoint2: NSPoint(x: 504, y: 600))
    nasal.close()
    NSGradient(colors: [color(0xDCE3EA), color(0x8995A3)])!.draw(in: nasal, angle: 0)
    color(0x46525F).setStroke(); nasal.lineWidth = 5; nasal.stroke()

    // Brow band with rivets.
    let band = NSBezierPath(roundedRect: NSRect(x: 344, y: 436, width: 336, height: 56), xRadius: 22, yRadius: 22)
    NSGradient(colors: [color(0xF6D27A), color(0xD39A3A), color(0x98611B)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(in: band, angle: -90)
    color(0x6B4210).setStroke(); band.lineWidth = 5; band.stroke()
    for x in stride(from: 378.0, through: 646.0, by: 44.7) {
        let rivet = NSBezierPath(ovalIn: NSRect(x: x - 9, y: 455, width: 18, height: 18))
        NSGradient(colors: [color(0xFFF2C4), color(0xA86E22)])!.draw(in: rivet, relativeCenterPosition: NSPoint(x: -0.4, y: 0.4))
        color(0x6B4210, 0.8).setStroke(); rivet.lineWidth = 2; rivet.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
}

let helmetScale: CGFloat = 0.78

/// One horn, rooted in the side of the dome and sweeping out and up. Drawn before the dome so the dome covers its root.
func drawHorn(mirrored: Bool) {
    NSGraphicsContext.saveGraphicsState()
    if mirrored {
        let flip = NSAffineTransform()
        flip.translateX(by: 1024, yBy: 0); flip.scaleX(by: -1, yBy: 1)
        flip.concat()
    }
    let horn = NSBezierPath()
    horn.move(to: NSPoint(x: 392, y: 448))                     // lower root
    horn.curve(to: NSPoint(x: 228, y: 352), controlPoint1: NSPoint(x: 300, y: 446), controlPoint2: NSPoint(x: 240, y: 418))
    horn.curve(to: NSPoint(x: 246, y: 196), controlPoint1: NSPoint(x: 214, y: 290), controlPoint2: NSPoint(x: 226, y: 232))
    horn.curve(to: NSPoint(x: 286, y: 326), controlPoint1: NSPoint(x: 252, y: 250), controlPoint2: NSPoint(x: 262, y: 300))
    horn.curve(to: NSPoint(x: 398, y: 364), controlPoint1: NSPoint(x: 312, y: 352), controlPoint2: NSPoint(x: 350, y: 366))
    horn.close()
    NSGradient(colors: [color(0xFFFBF0), color(0xEADFC4), color(0xC9B48A)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: horn, angle: mirrored ? 30 : 150)
    NSGraphicsContext.saveGraphicsState()
    horn.addClip()
    // Darker, worn tip.
    NSGradient(colors: [color(0x8A6A3C, 0.75), color(0x8A6A3C, 0)])!
        .draw(fromCenter: NSPoint(x: 246, y: 196), radius: 0, toCenter: NSPoint(x: 246, y: 196), radius: 90, options: [])
    // Growth rings.
    color(0x9C8257, 0.55).setStroke()
    for (start, end) in [(NSPoint(x: 300, y: 446), NSPoint(x: 318, y: 362)), (NSPoint(x: 248, y: 404), NSPoint(x: 276, y: 336)),
                         (NSPoint(x: 222, y: 330), NSPoint(x: 262, y: 300))] {
        let ring = NSBezierPath(); ring.move(to: start)
        ring.curve(to: end, controlPoint1: NSPoint(x: start.x - 12, y: (start.y + end.y) / 2), controlPoint2: NSPoint(x: end.x - 12, y: (start.y + end.y) / 2))
        ring.lineWidth = 5; ring.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    color(0x6E5632).setStroke(); horn.lineWidth = 6; horn.lineJoinStyle = .round; horn.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.translateX(by: 0, yBy: CGFloat(pixels))
    transform.scaleX(by: scale, yBy: -scale)
    transform.concat()
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { print("usage: make_app_icon.swift <output.iconset> [preview.png]"); exit(2) }
let iconset = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
if arguments.count >= 3 {
    try render(pixels: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
}
print("wrote \(iconset.path)")
