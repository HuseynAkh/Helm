#if os(macOS)
import AppKit
import XCTest
@testable import HelmUI

/// Helm's mark of AI mode, the trefoil: one looping line drawn in code, that renders without a window, tells lit from
/// unlit, and passes under itself with a clear gap at each of its three crossings.
@MainActor final class SparkMarkTests: XCTestCase {
    /// Draws an image into a bitmap of its own, with no window or screen, in the given appearance.
    private func render(_ image: NSImage, pixels: Int = 48, appearance: NSAppearance.Name = .aqua) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
    private func color(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor? {
        bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }
    private func pixels(_ bitmap: NSBitmapImageRep) -> [UInt8] {
        guard let data = bitmap.bitmapData else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }

    func testTheImageDrawsWithoutAWindow() throws {
        for lit in [false, true] {
            let image = SparkMark.image(size: 48, lit: lit)
            XCTAssertEqual(image.size, NSSize(width: 48, height: 48))
            let bitmap = try XCTUnwrap(render(image))
            // The top loop's tip and the two lower loops' feet are inked (the label colour is 85% black). The corners,
            // the hole in the top loop and the knot's open centre are clear.
            for (x, y) in [(24, 6), (10, 41), (37, 41)] {
                XCTAssertGreaterThan(color(bitmap, x, y)?.alphaComponent ?? 0, 0.8, "lit \(lit) at \(x), \(y)")
            }
            for (x, y) in [(1, 1), (46, 1), (1, 46), (46, 46), (6, 6), (41, 6), (24, 14), (24, 29)] {
                XCTAssertLessThan(color(bitmap, x, y)?.alphaComponent ?? 1, 0.05, "lit \(lit) at \(x), \(y)")
            }
        }
    }

    func testLitDiffersFromUnlit() throws {
        let unlit = SparkMark.image(size: 48, lit: false)
        let lit = SparkMark.image(size: 48, lit: true)
        XCTAssertTrue(unlit.isTemplate, "Unlit, it's tinted where it's used, as a symbol is.")
        XCTAssertFalse(lit.isTemplate, "Lit, it keeps its own colours.")
        let plain = try XCTUnwrap(render(unlit))
        let glowing = try XCTUnwrap(render(lit))
        XCTAssertNotEqual(pixels(plain), pixels(glowing))
        // Unlit it's the label colour, grey; lit, it runs from amber at the top loop towards violet at the lower two.
        let tip = try XCTUnwrap(color(plain, 24, 6))
        XCTAssertEqual(tip.redComponent, tip.blueComponent, accuracy: 0.05)
        let top = try XCTUnwrap(color(glowing, 24, 6))
        let bottom = try XCTUnwrap(color(glowing, 10, 41))
        XCTAssertGreaterThan(top.alphaComponent, 0.9)
        XCTAssertGreaterThan(bottom.alphaComponent, 0.9)
        XCTAssertGreaterThan(top.redComponent, top.blueComponent + 0.4, "amber at the top")
        XCTAssertGreaterThan(bottom.blueComponent, top.blueComponent + 0.2, "bluer towards the bottom")
        XCTAssertGreaterThan(top.redComponent, bottom.redComponent + 0.1)
    }

    func testTheGradientsColoursAreAmberCoralAndViolet() {
        let colours = SparkMark.gradientColors.compactMap { $0.usingColorSpace(.sRGB) }
        XCTAssertEqual(colours.count, 3)
        guard colours.count == 3 else { return }
        XCTAssertGreaterThan(colours[0].redComponent, colours[0].blueComponent, "amber")
        XCTAssertGreaterThan(colours[1].redComponent, colours[1].greenComponent, "coral")
        XCTAssertGreaterThan(colours[2].blueComponent, colours[2].redComponent, "violet")
    }

    func testThePathIsOneLineLoopingThreeTimesRoundAnOpenCentre() {
        let rect = CGRect(x: 10, y: 20, width: 40, height: 40)
        let path = SparkMark.path(in: rect)
        // As wide as the rect, and a little less tall: the knot is wider than it is high.
        XCTAssertEqual(path.boundingBox.minX, rect.minX, accuracy: 0.05)
        XCTAssertEqual(path.boundingBox.maxX, rect.maxX, accuracy: 0.05)
        XCTAssertGreaterThan(path.boundingBox.minY, rect.minY)
        XCTAssertLessThan(path.boundingBox.maxY, rect.maxY)
        XCTAssertEqual(path.boundingBox.midY, rect.midY, accuracy: 0.05)
        // The centre is open, and so is the top loop's hole; the line runs through the top loop's tip.
        XCTAssertFalse(path.contains(CGPoint(x: rect.midX, y: rect.midY - 2)))
        XCTAssertFalse(path.contains(CGPoint(x: rect.midX, y: rect.midY + 10)))
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: path.boundingBox.maxY - 1)))
        // Three crossings, the trefoil's: one under the centre and two either side of it, mirror images, and at each
        // the line passes over once and under once.
        let crossings = SparkMark.knot.crossings
        XCTAssertEqual(crossings.count, 3)
        let points = crossings.map(\.point).sorted { $0.x < $1.x }
        guard points.count == 3 else { return }
        XCTAssertEqual(points[1].x, 0, accuracy: 0.01)
        XCTAssertLessThan(points[1].y, -0.5)
        XCTAssertEqual(points[0].x, -points[2].x, accuracy: 0.01)
        XCTAssertEqual(points[0].y, points[2].y, accuracy: 0.01)
        for crossing in crossings { XCTAssertGreaterThan(abs(crossing.over - crossing.under), 0.1) }
    }

    func testTheLinePassesUnderItselfThroughAClearGap() throws {
        // At 64 points, drawn at 2x: each crossing is inked by the strand on top, and the strand underneath is cut
        // either side of it, clear through.
        let bitmap = try XCTUnwrap(render(SparkMark.image(size: 64, lit: true), pixels: 128))
        let sites = SparkMark.crossingsForTesting(in: CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertEqual(sites.count, 3)
        for site in sites {
            let crossing = color(bitmap, Int(site.crossing.x * 2), Int((64 - site.crossing.y) * 2))
            let gap = color(bitmap, Int(site.gap.x * 2), Int((64 - site.gap.y) * 2))
            XCTAssertGreaterThan(crossing?.alphaComponent ?? 0, 0.95, "\(site.crossing)")
            XCTAssertLessThan(gap?.alphaComponent ?? 1, 0.1, "\(site.gap)")
        }
    }

    func testTheSmallestMarkKeepsItsLoopsOpen() throws {
        // The status bar's 10-point mark at 2x: down its middle, the top loop's tip, its hole, the line across it,
        // the open centre, the lower crossing, and clear again below.
        let bitmap = try XCTUnwrap(render(SparkMark.image(size: 10, lit: false), pixels: 20))
        let column = (0..<20).map { color(bitmap, 10, $0)?.alphaComponent ?? 0 }
        let inked = column.map { $0 > 0.5 }
        var runs: [Bool] = []
        for value in inked where runs.last != value { runs.append(value) }
        XCTAssertEqual(runs, [false, true, false, true, false, true, false], "\(column)")
        XCTAssertLessThan(SparkMark.weight(ink: 10 * (1 - 2 * SparkMark.inset)), 1.05, "about a point wide")
    }

    func testAnImageShownLargerIsWeighedForTheSizeItsShownAt() throws {
        // Settings' toolbar shows its 18-point tab image at about 29 points. Drawn there at 2x, its line is as heavy
        // as a 29-point mark's, not as an 18-point mark's line scaled up.
        func ink(_ image: NSImage) throws -> CGFloat {
            let bitmap = try XCTUnwrap(render(image, pixels: 58))
            var total: CGFloat = 0
            for y in 0..<58 { for x in 0..<58 { total += color(bitmap, x, y)?.alphaComponent ?? 0 } }
            return total
        }
        let shown = try ink(SparkMark.image(size: 18, lit: false))
        let native = try ink(SparkMark.image(size: 29, lit: false))
        XCTAssertEqual(shown / native, 1, accuracy: 0.03)
        XCTAssertEqual(SparkMark.shownScale(of: try XCTUnwrap(scaledContext(2))), 1, "A Retina screen at the image's size")
        XCTAssertEqual(SparkMark.shownScale(of: try XCTUnwrap(scaledContext(1))), 1, "A 1x screen at the image's size")
        XCTAssertEqual(SparkMark.shownScale(of: try XCTUnwrap(scaledContext(3.2))), 1.6, accuracy: 0.001)
    }
    private func scaledContext(_ scale: CGFloat) -> CGContext? {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.scaleBy(x: scale, y: scale)
        return context
    }

    func testTheShimmerTurnsTheGradient() throws {
        func draw(turn: CGFloat) -> [UInt8] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return [] }
            SparkMark.drawGradient(in: CGRect(x: 0, y: 0, width: 32, height: 32), context: context.cgContext, turn: turn)
            context.flushGraphics()
            return pixels(bitmap)
        }
        /// The largest difference in any channel of any pixel.
        func difference(_ first: [UInt8], _ second: [UInt8]) -> Int {
            zip(first, second).map { abs(Int($0) - Int($1)) }.max() ?? .max
        }
        let still = draw(turn: 0)
        XCTAssertFalse(still.isEmpty)
        XCTAssertLessThanOrEqual(difference(still, draw(turn: 1)), 2, "A whole turn comes back to the still mark.")
        XCTAssertGreaterThan(difference(still, draw(turn: 0.25)), 60, "A quarter turn moves the colours.")
    }
}
#endif
