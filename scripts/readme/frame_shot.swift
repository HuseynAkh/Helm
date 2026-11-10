// Frames a window capture for the README: rounded corners like a macOS 26 window, a hairline edge and a soft
// shadow on a clear background, scaled to a width that suits a GitHub page.
// usage: swift scripts/readme/frame_shot.swift <in.png> <out.png> [width-px] [corner-radius-pt] [plain]
// The capture is taken at the screen's pixel density (2x on a Retina display), so the radius is given in points.
// "plain" skips the corners and edge, for pictures that already have their own shape, such as a popover.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: frame_shot.swift <in.png> <out.png> [width-px] [corner-radius-pt] [plain]\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let targetWidth = arguments.count > 3 ? Double(arguments[3]) ?? 1600 : 1600
let radiusPoints = arguments.count > 4 ? Double(arguments[4]) ?? 26 : 26
let plain = arguments.count > 5 && arguments[5] == "plain"

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("can't read \(input.path)\n".utf8)); exit(1)
}
// The capture is 2x, so a point is two pixels before scaling.
let scale = min(1, targetWidth / Double(image.width))
let width = Double(image.width) * scale
let height = Double(image.height) * scale
let radius = radiusPoints * 2 * scale
// Room around the window for its shadow, more below than above, as macOS draws it.
let shadowBlur = 44 * scale * 2
let pad = (top: shadowBlur * 0.8, side: shadowBlur, bottom: shadowBlur * 1.3)
let canvasWidth = Int((width + pad.side * 2).rounded())
let canvasHeight = Int((height + pad.top + pad.bottom).rounded())

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
context.interpolationQuality = .high
// CoreGraphics counts y from the bottom.
let frame = CGRect(x: pad.side, y: pad.bottom, width: width, height: height)
let shape = plain ? CGPath(rect: frame, transform: nil) : CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

// The shadow: a soft, wide one and a tight one close to the edge.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18 * scale * 2), blur: shadowBlur, color: CGColor(gray: 0, alpha: 0.38))
context.addPath(shape); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fillPath()
context.restoreGState()
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -2 * scale * 2), blur: 6 * scale * 2, color: CGColor(gray: 0, alpha: 0.25))
context.addPath(shape); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fillPath()
context.restoreGState()

// The window itself, clipped to its corners.
context.saveGState()
context.addPath(shape); context.clip()
context.draw(image, in: frame)
context.restoreGState()

// A hairline edge, light on dark windows and dark on light ones, as macOS draws it.
if !plain {
    let sample = averageBrightness(of: image)
    context.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setStrokeColor(sample < 0.5 ? CGColor(gray: 1, alpha: 0.18) : CGColor(gray: 0, alpha: 0.16))
    context.setLineWidth(1)
    context.strokePath()
}

guard let framed = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, framed, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("\(output.lastPathComponent): \(canvasWidth)x\(canvasHeight)")

/// How light the picture is overall, from 0 (black) to 1 (white), read from a small copy of it.
func averageBrightness(of image: CGImage) -> Double {
    let size = 16
    guard let gray = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0.5 }
    gray.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let data = gray.data else { return 0.5 }
    let pixels = data.bindMemory(to: UInt8.self, capacity: size * size)
    var total = 0
    for index in 0..<(size * size) { total += Int(pixels[index]) }
    return Double(total) / Double(size * size * 255)
}
