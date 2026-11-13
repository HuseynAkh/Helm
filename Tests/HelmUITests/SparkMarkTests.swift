#if os(macOS)
import AppKit
import XCTest
@testable import HelmUI

/// Helm's spark: one shape, drawn in code, that renders without a window and tells lit from unlit.
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
            // The centre is filled (the label colour is 85% black), and the corners, outside the four points, are clear.
            XCTAssertGreaterThan(color(bitmap, 24, 24)?.alphaComponent ?? 0, 0.8, "lit \(lit)")
            for (x, y) in [(1, 1), (46, 1), (1, 46), (46, 46), (8, 8), (39, 39)] {
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
        // Unlit it's the label colour, grey; lit, it runs from amber at the top towards violet at the bottom.
        let middle = try XCTUnwrap(color(plain, 24, 24))
        XCTAssertEqual(middle.redComponent, middle.blueComponent, accuracy: 0.05)
        let top = try XCTUnwrap(color(glowing, 24, 14))
        let bottom = try XCTUnwrap(color(glowing, 24, 33))
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

    func testThePathHasFourPointsOnTheEdgesMiddles() {
        let rect = CGRect(x: 10, y: 20, width: 40, height: 40)
        let path = SparkMark.path(in: rect)
        XCTAssertEqual(path.boundingBox.minX, rect.minX, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.maxX, rect.maxX, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.minY, rect.minY, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.maxY, rect.maxY, accuracy: 0.01)
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
        // Each point reaches its edge's middle.
        for tip in [CGPoint(x: rect.midX, y: rect.maxY - 1), CGPoint(x: rect.midX, y: rect.minY + 1),
                    CGPoint(x: rect.minX + 1, y: rect.midY), CGPoint(x: rect.maxX - 1, y: rect.midY)] {
            XCTAssertTrue(path.contains(tip), "\(tip)")
        }
        // The sides curve in: the middle of each corner's diagonal is outside the spark.
        for corner in [CGPoint(x: rect.minX + 10, y: rect.minY + 10), CGPoint(x: rect.maxX - 10, y: rect.maxY - 10),
                       CGPoint(x: rect.minX + 10, y: rect.maxY - 10), CGPoint(x: rect.maxX - 10, y: rect.minY + 10)] {
            XCTAssertFalse(path.contains(corner), "\(corner)")
        }
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
