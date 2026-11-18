#if os(macOS)
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmUI

/// Helm's reading of real photos, the ones every Mac keeps in /Library/User Pictures: what Apple's on-device
/// recognition says each shows, and the copy a model gets. The pictures there are links to the real files, which
/// Helm never opens, so each test reads the file a link points to.
final class AgentRealPictureTests: XCTestCase {
    private var folder: TempDirectory!
    override func setUpWithError() throws { folder = try TempDirectory() }
    override func tearDownWithError() throws { try folder.remove() }

    /// The real file behind one of macOS's sample pictures, or a skip on a Mac without them.
    private func sample(_ name: String) throws -> String {
        let path = URL(fileURLWithPath: "/Library/User Pictures/\(name).heic").resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("no sample picture \(name)") }
        return path
    }
    private func summary(_ path: String) -> AgentContentSummary {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let request = AgentContentRequest(path: path, name: (path as NSString).lastPathComponent, identity: nil,
                                          typeIdentifier: nil, size: size, modified: Date(), isDataless: false, wantsImages: true)
        return AgentContentExtractor.summary(of: request, deadline: .now() + 30)
    }
    private func decoded(_ jpeg: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    /// RGBA pixels of an image drawn at `side` × `side`.
    private func pixels(_ image: CGImage, side: Int = 64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return bytes
    }
    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
    }
    private func write(_ image: CGImage, as type: UTType, to name: String, properties: [CFString: Any] = [:]) -> String {
        let url = folder.url.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url.path
    }
    private func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// What the recognition names, for photos it knows well. The recognizer changes with macOS, so most, not all.
    func testOnDeviceRecognitionNamesWhatClearPhotosShow() throws {
        let expected = ["Animals/Eagle": "eagle", "Animals/Owl": "owl", "Animals/Penguin": "penguin", "Animals/Zebra": "zebra",
                        "Flowers/Sunflower": "sunflower", "Flowers/Red Rose": "rose", "Instruments/Violin": "violin",
                        "Instruments/Guitar": "guitar", "Nature/Lightning": "lightning", "Sports/Golf": "golf"]
        var named: [String] = []
        for (name, label) in expected.sorted(by: { $0.key < $1.key }) {
            let read = summary(try sample(name))
            XCTAssertEqual(read.status, .read, name)
            XCTAssertEqual(read.kind, .image, name)
            if read.labels.contains(where: { $0.identifier == label }) { named.append(name) }
        }
        XCTAssertGreaterThanOrEqual(named.count, 8, "named only \(named)")
    }

    /// Every sample photo is read, and its copy for a model is a JPEG at most 512 pixels a side with no metadata.
    func testTheCopyForAModelIsSmallAndHasNoMetadata() throws {
        for name in ["Animals/Parrot", "Flowers/Lotus", "Fun/Fortune Cookie", "Sports/Basketball", "Nature/Snowflake"] {
            let read = summary(try sample(name))
            XCTAssertEqual(read.status, .read, name)
            let copy = try XCTUnwrap(read.images.first, name)
            XCTAssertEqual(read.images.count, 1, name)
            XCTAssertEqual(copy.source, .picture, name)
            XCTAssertLessThanOrEqual(max(copy.width, copy.height), AgentContentLimits.lookEdge, name)
            XCTAssertTrue(AgentContentExtractor.hasNoMetadata(copy.jpeg), name)
            let image = try decoded(copy.jpeg)
            XCTAssertEqual([image.width, image.height], [copy.width, copy.height], name)
        }
    }

    /// A photo stored on its side, with an orientation tag that turns it upright and made-up GPS, as a phone writes
    /// one: the model's copy is upright, the same picture as the upright photo's copy, and the GPS is gone.
    func testAPhotoStoredOnItsSideReachesTheModelUprightWithoutItsLocation() throws {
        let upright = try decoded(XCTUnwrap(summary(try sample("Animals/Zebra")).images.first?.jpeg))
        let zebraSource = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: try sample("Animals/Zebra")) as CFURL, nil))
        let zebra = try XCTUnwrap(CGImageSourceCreateImageAtIndex(zebraSource, 0, nil))
        // The pixels turned a quarter to the left, tagged 6 so a viewer turns them a quarter to the right, upright.
        let side = context(zebra.height, zebra.width)
        side.translateBy(x: CGFloat(zebra.height), y: 0); side.rotate(by: .pi / 2)
        side.draw(zebra, in: CGRect(x: 0, y: 0, width: zebra.width, height: zebra.height))
        let stored = try XCTUnwrap(side.makeImage())
        let path = write(stored, as: .jpeg, to: "IMG_0001.JPG", properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 64.1466, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 21.9426, kCGImagePropertyGPSLongitudeRef: "W"]])
        let written = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertNotNil(written?[kCGImagePropertyGPSDictionary], "the test photo carries a location")

        let read = summary(path)
        XCTAssertEqual(read.status, .read)
        XCTAssertTrue(read.labels.contains { $0.identifier == "zebra" }, "recognized upright: \(read.labels.map(\.identifier))")
        let copy = try XCTUnwrap(read.images.first)
        XCTAssertTrue(AgentContentExtractor.hasNoMetadata(copy.jpeg))
        let sent = try decoded(copy.jpeg)
        let turned = difference(pixels(sent), pixels(stored))
        let same = difference(pixels(sent), pixels(upright))
        XCTAssertLessThan(same, 12, "the copy matches the upright photo")
        XCTAssertLessThan(same * 2, turned, "the copy isn't the stored, sideways pixels (\(same) vs \(turned))")
    }

    /// A picture with transparency reaches the model on white, not on black.
    func testTransparencyReachesTheModelOnWhite() throws {
        let guitarSource = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: try sample("Instruments/Guitar")) as CFURL, nil))
        let guitar = try XCTUnwrap(CGImageSourceCreateImageAtIndex(guitarSource, 0, nil))
        let cut = context(guitar.width, guitar.height)
        cut.clear(CGRect(x: 0, y: 0, width: guitar.width, height: guitar.height))
        cut.addEllipse(in: CGRect(x: 0, y: 0, width: guitar.width, height: guitar.height)); cut.clip()
        cut.draw(guitar, in: CGRect(x: 0, y: 0, width: guitar.width, height: guitar.height))
        let path = write(try XCTUnwrap(cut.makeImage()), as: .png, to: "Untitled.png")
        let copy = try XCTUnwrap(summary(path).images.first)
        let corner = pixels(try decoded(copy.jpeg), side: 32).prefix(4)
        XCTAssertGreaterThan(corner.prefix(3).map(Int.init).min() ?? 0, 240, "a transparent corner is white: \(Array(corner))")
    }

    /// A 48-megapixel photo is read and comes down to the model's size.
    func testALargePhotoIsReadAndScaledDown() throws {
        let sunflowerSource = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: try sample("Flowers/Sunflower")) as CFURL, nil))
        let sunflower = try XCTUnwrap(CGImageSourceCreateImageAtIndex(sunflowerSource, 0, nil))
        let big = context(8000, 6000)
        big.draw(sunflower, in: CGRect(x: 0, y: 0, width: 8000, height: 6000))
        let path = write(try XCTUnwrap(big.makeImage()), as: .jpeg, to: "DSC00001.JPG",
                         properties: [kCGImageDestinationLossyCompressionQuality: 0.7])
        let read = summary(path)
        XCTAssertEqual(read.status, .read)
        let copy = try XCTUnwrap(read.images.first)
        XCTAssertEqual(max(copy.width, copy.height), AgentContentLimits.lookEdge)
        XCTAssertEqual(copy.width * 3, copy.height * 4, "keeps its shape: \(copy.width)x\(copy.height)")
    }
}
#endif
