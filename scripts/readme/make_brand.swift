// Draws Helm's brand pictures in docs/brand: the spark, the mark of AI mode, and the README's banner, which is the
// app icon with the spark beside it. Everything is drawn here, with no image service and no network.
// usage: swift scripts/readme/make_brand.swift <app-icon.icns> <out-dir>
// The spark's shape and colours are the ones Sources/HelmUI/Agent/SparkMark.swift draws in the app. The icon is
// read from the app's own icon file and is never changed.
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

// MARK: The spark, as SparkMark draws it

/// Amber, coral and violet, from top to bottom, as in SparkMark.gradientColors.
let sparkColors: [CGColor] = [
    CGColor(srgbRed: 1.00, green: 0.71, blue: 0.20, alpha: 1),
    CGColor(srgbRed: 0.98, green: 0.44, blue: 0.38, alpha: 1),
    CGColor(srgbRed: 0.56, green: 0.36, blue: 0.96, alpha: 1)
]
let reach: CGFloat = 0.30
let lean: CGFloat = 0.06

/// The four points and the eight control points of the spark in `rect`, top point first, going clockwise in
/// unflipped coordinates. The same sums as SparkMark.path(in:).
func sparkSegments(in rect: CGRect) -> (start: CGPoint, curves: [(CGPoint, CGPoint, CGPoint)]) {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let arms = [CGVector(dx: 0, dy: rect.height / 2), CGVector(dx: rect.width / 2, dy: 0),
                CGVector(dx: 0, dy: -rect.height / 2), CGVector(dx: -rect.width / 2, dy: 0)]
    func point(_ first: CGVector, _ firstShare: CGFloat, _ second: CGVector, _ secondShare: CGFloat) -> CGPoint {
        CGPoint(x: center.x + first.dx * firstShare + second.dx * secondShare,
                y: center.y + first.dy * firstShare + second.dy * secondShare)
    }
    var curves: [(CGPoint, CGPoint, CGPoint)] = []
    for index in arms.indices {
        let from = arms[index], to = arms[(index + 1) % arms.count]
        curves.append((point(from, reach, to, lean), point(to, reach, from, lean), point(to, 1, to, 0)))
    }
    return (point(arms[0], 1, arms[0], 0), curves)
}

func sparkPath(in rect: CGRect) -> CGPath {
    let segments = sparkSegments(in: rect)
    let path = CGMutablePath()
    path.move(to: segments.start)
    for (control1, control2, end) in segments.curves { path.addCurve(to: end, control1: control1, control2: control2) }
    path.closeSubpath()
    return path
}

/// The spark filled with its gradient, amber at the top to violet at the bottom.
func drawSpark(in rect: CGRect, context: CGContext) {
    let gradient = CGGradient(colorsSpace: sRGB, colors: sparkColors as CFArray, locations: [0, 0.5, 1])!
    context.saveGState()
    context.addPath(sparkPath(in: rect))
    context.clip()
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

/// A soft glow, drawn flat as the AI mode screen draws its own, so every viewer sees the same picture.
func drawGlow(at center: CGPoint, radius: CGFloat, strength: CGFloat, context: CGContext, scaleY: CGFloat = 0.62) {
    let colors = [rgb(0xFFB533, 0.55 * strength), rgb(0xFA7061, 0.32 * strength), rgb(0x8F5CF5, 0.20 * strength),
                  rgb(0x8F5CF5, 0)]
    let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: [0, 0.35, 0.7, 1])!
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.scaleBy(x: 1, y: scaleY)
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

// The spark alone, on a clear background.
do {
    let size = 1024
    let context = makeContext(width: size, height: size)
    let inset = CGFloat(size) * 0.08
    drawSpark(in: CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset), context: context)
    writePNG(context, "spark.png")
}

// The same spark as SVG, written from the same points, so it stays sharp at any size.
do {
    let size: CGFloat = 256
    let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.08, dy: size * 0.08)
    let segments = sparkSegments(in: rect)
    // SVG counts y from the top, so every y is turned over.
    func spot(_ point: CGPoint) -> String {
        String(format: "%.2f %.2f", point.x, size - point.y)
    }
    var d = "M \(spot(segments.start))"
    for (control1, control2, end) in segments.curves { d += " C \(spot(control1)), \(spot(control2)), \(spot(end))" }
    d += " Z"
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

struct Look { let name: String; let background: [UInt32]; let title: NSColor; let line: NSColor; let edge: CGColor; let glow: CGFloat }
let looks = [
    Look(name: "banner-light.png", background: [0xFFFFFF, 0xF4F1EC], title: NSColor(white: 0.08, alpha: 1),
         line: NSColor(white: 0.36, alpha: 1), edge: CGColor(gray: 0, alpha: 0.08), glow: 0.75),
    Look(name: "banner-dark.png", background: [0x17161C, 0x0B0B0F], title: NSColor(white: 0.97, alpha: 1),
         line: NSColor(white: 0.66, alpha: 1), edge: CGColor(gray: 1, alpha: 0.10), glow: 1.0)
]

for look in looks {
    let width = 2400, height = 800
    let w = CGFloat(width), h = CGFloat(height)
    let context = makeContext(width: width, height: height)
    let card = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: 2, dy: 2), cornerWidth: 56, cornerHeight: 56, transform: nil)
    context.saveGState()
    context.addPath(card)
    context.clip()
    let background = CGGradient(colorsSpace: sRGB, colors: look.background.map { rgb($0) } as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

    // The icon on the left, the spark beside it at its upper right, and one glow behind both.
    let iconSize: CGFloat = 440
    let iconFrame = CGRect(x: 230, y: (h - iconSize) / 2 - 6, width: iconSize, height: iconSize)
    let sparkSize: CGFloat = 168
    let sparkFrame = CGRect(x: iconFrame.maxX - 18, y: iconFrame.maxY - sparkSize * 0.62, width: sparkSize, height: sparkSize)
    drawGlow(at: CGPoint(x: sparkFrame.midX - 40, y: sparkFrame.midY - 60), radius: 620, strength: look.glow, context: context)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 44, color: CGColor(gray: 0, alpha: 0.30))
    context.draw(iconImage, in: iconFrame)
    context.restoreGState()
    drawSpark(in: sparkFrame, context: context)

    // The name and one line under it.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let textX = iconFrame.maxX + 230
    let title = NSAttributedString(string: "Helm", attributes: [
        .font: NSFont.systemFont(ofSize: 196, weight: .bold), .foregroundColor: look.title, .kern: -4])
    title.draw(at: CGPoint(x: textX, y: h / 2 - 10))
    let line = NSAttributedString(string: "The agentic file manager for Mac.", attributes: [
        .font: NSFont.systemFont(ofSize: 64, weight: .regular), .foregroundColor: look.line])
    line.draw(at: CGPoint(x: textX + 6, y: h / 2 - 110))
    NSGraphicsContext.restoreGraphicsState()
    context.restoreGState()

    // A hairline edge round the card.
    context.addPath(card)
    context.setStrokeColor(look.edge)
    context.setLineWidth(2)
    context.strokePath()
    writePNG(context, look.name)
}
