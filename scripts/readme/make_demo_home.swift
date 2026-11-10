// Builds a demo home folder for README screenshots: made-up documents, pictures and projects, all drawn here,
// so no screenshot ever shows anything from a real Mac.
// Usage: swift scripts/readme/make_demo_home.swift <home>
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else { print("usage: make_demo_home.swift <home>"); exit(2) }
let home = URL(fileURLWithPath: arguments[1], isDirectory: true)
let manager = FileManager.default
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func folder(_ path: String) -> URL {
    let url = home.appendingPathComponent(path, isDirectory: true)
    try? manager.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func write(_ text: String, to path: String) {
    try? text.write(to: home.appendingPathComponent(path), atomically: true, encoding: .utf8)
}
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// MARK: Pictures: landscapes made of a gradient sky, a sun and layered hills

struct Palette { let sky: [UInt32]; let sun: UInt32; let hills: [UInt32] }
let palettes: [(String, Palette)] = [
    ("Sunset over the Bay", Palette(sky: [0x2B1B4F, 0xC2456B, 0xF7A65A], sun: 0xFFE3A3, hills: [0x5A2E5C, 0x3B1F45, 0x22132B])),
    ("Morning in the Alps", Palette(sky: [0x8EC5FF, 0xCFE7FF, 0xFFF3DA], sun: 0xFFFFFF, hills: [0x7FA7C9, 0x55799E, 0x2F4E6E])),
    ("Desert Road", Palette(sky: [0xF6B26B, 0xFAD7A0, 0xFFF1D6], sun: 0xFFF8E1, hills: [0xD9883E, 0xB5652A, 0x7A3F1C])),
    ("Northern Lights", Palette(sky: [0x07131F, 0x0D3B4C, 0x1FA67A], sun: 0xC8FFE9, hills: [0x0B2230, 0x071822, 0x030C12])),
    ("Forest Lake", Palette(sky: [0xB9E4D2, 0xE3F4EC, 0xF8FCFA], sun: 0xFFFFFF, hills: [0x5E9C76, 0x3E7457, 0x234A36])),
    ("Lavender Fields", Palette(sky: [0x6A5ACD, 0xB59CE0, 0xF1D9F7], sun: 0xFFF0FA, hills: [0x8E6CC9, 0x6B4AA8, 0x45307A])),
]

func landscape(_ palette: Palette, seed: Int, width: Int = 1800, height: Int = 1200) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let w = CGFloat(width), h = CGFloat(height)
    let sky = CGGradient(colorsSpace: sRGB, colors: palette.sky.map { rgb($0) } as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.25), options: [.drawsAfterEndLocation])
    // The sun, with a soft glow.
    let sunCenter = CGPoint(x: w * (0.25 + 0.1 * CGFloat(seed % 5)), y: h * 0.58)
    let glow = CGGradient(colorsSpace: sRGB, colors: [rgb(palette.sun, 0.55), rgb(palette.sun, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: sunCenter, startRadius: 0, endCenter: sunCenter, endRadius: h * 0.32, options: [])
    ctx.setFillColor(rgb(palette.sun)); ctx.fillEllipse(in: CGRect(x: sunCenter.x - h * 0.07, y: sunCenter.y - h * 0.07, width: h * 0.14, height: h * 0.14))
    // Three ranges of hills, each a smooth curve through a few points.
    for (layer, color) in palette.hills.enumerated() {
        let base = h * (0.42 - 0.12 * CGFloat(layer))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: 0, y: base))
        let steps = 6
        for step in 1...steps {
            let x = w * CGFloat(step) / CGFloat(steps)
            let wave = sin(CGFloat(step * (seed + 3) + layer * 2)) * h * 0.06 + cos(CGFloat(step + seed * layer)) * h * 0.03
            let control = CGPoint(x: x - w / CGFloat(steps * 2), y: base + wave + h * 0.05)
            path.addQuadCurve(to: CGPoint(x: x, y: base + wave * 0.6), control: control)
        }
        path.addLine(to: CGPoint(x: w, y: 0)); path.closeSubpath()
        ctx.addPath(path); ctx.setFillColor(rgb(color)); ctx.fillPath()
    }
    return ctx.makeImage()!
}

func writeJPEG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])?.write(to: url)
}
func writePNG(_ image: CGImage, to url: URL) {
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
}

let pictures = folder("Pictures")
for (index, (name, palette)) in palettes.enumerated() {
    writeJPEG(landscape(palette, seed: index + 1), to: pictures.appendingPathComponent("\(name).jpg"))
}
let wallpapers = folder("Pictures/Wallpapers")
for (index, (name, palette)) in palettes.prefix(3).enumerated() {
    writeJPEG(landscape(palette, seed: index + 7, width: 2560, height: 1600), to: wallpapers.appendingPathComponent("\(name) Wide.jpg"))
}

// MARK: Documents: PDFs with a title, headings, text lines and a small chart

func pdf(title: String, subtitle: String, accent: UInt32, pages: Int, chart: Bool, to url: URL) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    for page in 0..<pages {
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(box)
        ctx.setFillColor(rgb(accent)); ctx.fill(CGRect(x: 0, y: 742, width: 612, height: 50))
        let titleText = page == 0 ? title : "\(title) — \(page + 1)"
        (titleText as NSString).draw(at: CGPoint(x: 48, y: 690), withAttributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor(white: 0.1, alpha: 1)])
        (subtitle as NSString).draw(at: CGPoint(x: 48, y: 664), withAttributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor(white: 0.45, alpha: 1)])
        var y: CGFloat = 620
        if chart && page == 0 {
            let values: [CGFloat] = [0.42, 0.58, 0.51, 0.74, 0.69, 0.88]
            for (index, value) in values.enumerated() {
                ctx.setFillColor(rgb(accent, index == values.count - 1 ? 1 : 0.55))
                ctx.fill(CGRect(x: 60 + CGFloat(index) * 82, y: 430, width: 52, height: 170 * value))
            }
            y = 400
        }
        for line in 0..<18 where y > 70 {
            let width: CGFloat = line % 6 == 5 ? 300 : 516 - CGFloat((line * 37) % 90)
            ctx.setFillColor(rgb(line % 6 == 0 ? 0x3A3A3C : 0xC7C7CC)); ctx.fill(CGRect(x: 48, y: y, width: width, height: line % 6 == 0 ? 9 : 6))
            y -= line % 6 == 5 ? 30 : 18
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

let documents = folder("Documents")
pdf(title: "Quarterly Report", subtitle: "Q3 2026 · Growth and milestones", accent: 0x0A84FF, pages: 3, chart: true,
    to: documents.appendingPathComponent("Quarterly Report.pdf"))
pdf(title: "Product Roadmap", subtitle: "What ships next, and why", accent: 0xFF9F0A, pages: 2, chart: false,
    to: documents.appendingPathComponent("Product Roadmap.pdf"))
pdf(title: "Field Guide", subtitle: "Trails, lakes and lookouts", accent: 0x30D158, pages: 4, chart: false,
    to: documents.appendingPathComponent("Field Guide.pdf"))
write("""
# Meeting notes

- Ship the new sidebar settings
- Review the onboarding copy
- Plan the 1.0 release notes

> Finder underneath, Nautilus on top.
""", to: "Documents/Meeting Notes.md")
write("Ideas\n\n1. A calmer header\n2. Folders apart from files in Recent\n3. Smooth list animations\n", to: "Documents/Ideas.txt")
write("Month,Design,Engineering,Research\nJanuary,1200,3400,800\nFebruary,1350,3600,950\nMarch,1500,3550,1020\n", to: "Documents/Budget 2027.csv")
let invoices = folder("Documents/Invoices")
for (index, month) in ["August", "September", "October"].enumerated() {
    pdf(title: "Invoice \(1042 + index)", subtitle: "\(month) 2026 · Studio Maple", accent: 0x5E5CE6, pages: 1, chart: false,
        to: invoices.appendingPathComponent("Invoice \(month).pdf"))
}
let project = folder("Documents/Projects/Lighthouse")
write("# Lighthouse\n\nA tiny weather app for walkers.\n", to: "Documents/Projects/Lighthouse/README.md")
write("import SwiftUI\n\n@main\nstruct LighthouseApp: App {\n    var body: some Scene {\n        WindowGroup { ContentView() }\n    }\n}\n",
      to: "Documents/Projects/Lighthouse/LighthouseApp.swift")
write("// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Lighthouse\")\n",
      to: "Documents/Projects/Lighthouse/Package.swift")
let assets = folder("Documents/Projects/Lighthouse/Assets")
writePNG(landscape(palettes[4].1, seed: 11, width: 1024, height: 1024), to: assets.appendingPathComponent("AppIcon.png"))
_ = project
_ = folder("Documents/Projects/Field Notes")
write("Day 1: clear skies.\n", to: "Documents/Projects/Field Notes/Day 1.txt")

// MARK: Desktop and Downloads

let desktop = folder("Desktop")
writePNG(landscape(palettes[1].1, seed: 13, width: 1440, height: 900), to: desktop.appendingPathComponent("Screenshot 2026-11-08 at 10.42.12.png"))
_ = folder("Desktop/Moodboard")
for (index, (_, palette)) in palettes.suffix(3).enumerated() {
    writeJPEG(landscape(palette, seed: index + 17, width: 1200, height: 1200), to: desktop.appendingPathComponent("Moodboard/Swatch \(index + 1).jpg"))
}
let downloads = folder("Downloads")
pdf(title: "Boarding Pass", subtitle: "Flight HL 204 · Seat 12A", accent: 0xFF375F, pages: 1, chart: false,
    to: downloads.appendingPathComponent("Boarding Pass.pdf"))
let poster = Palette(sky: [0x14082E, 0x7A1FA2, 0xFF5E8A], sun: 0xFFD166, hills: [0x2E1A6B, 0x1C1147, 0x0D0826])
writeJPEG(landscape(poster, seed: 21), to: downloads.appendingPathComponent("Concert Poster.jpg"))
write("Thanks for downloading!\n", to: "Downloads/Read Me.txt")
let zip = Process()
zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
zip.arguments = ["-c", "-k", "--keepParent", home.appendingPathComponent("Documents/Invoices").path,
                 downloads.appendingPathComponent("Invoices.zip").path]
try? zip.run(); zip.waitUntilExit()

for name in ["Music", "Movies", "Library", "Templates"] { _ = folder(name) }

// MARK: iCloud Drive and the Trash

// Stand-ins where a real Mac keeps them, so the sidebar shows iCloud Drive and the Trash has something in it.
_ = folder("Library/Mobile Documents/com~apple~CloudDocs/Travel")
write("Packing list\n\n- Rain jacket\n- Camera\n- Trail map\n", to: "Library/Mobile Documents/com~apple~CloudDocs/Travel/Packing List.txt")
write("Reading list\n\n1. A book about old forests\n2. A field guide to mosses\n", to: "Library/Mobile Documents/com~apple~CloudDocs/Reading List.txt")
_ = folder(".Trash")
write("An old draft.\n", to: ".Trash/Old Draft.txt")
// MARK: Dates

// Dates spread over the last few weeks, the same on every run, so lists read like a Mac in use.
func stableNumber(_ text: String) -> Int {
    var value: UInt64 = 5381
    for byte in text.utf8 { value = (value &* 33) ^ UInt64(byte) }
    return Int(value % 100_000)
}
let calendar = Calendar.current
let startOfToday = calendar.startOfDay(for: Date())
func day(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
    calendar.date(byAdding: DateComponents(day: -daysAgo, hour: hour, minute: minute), to: startOfToday) ?? Date()
}
let pinnedDates: [String: Date] = [
    "Documents/Quarterly Report.pdf": day(0, 9, 41),
    "Documents/Meeting Notes.md": day(1, 16, 20),
    "Documents/Product Roadmap.pdf": day(1, 11, 5),
    "Downloads/Concert Poster.jpg": day(2, 19, 30),
    "Downloads/Boarding Pass.pdf": day(3, 7, 55),
]
let homePath = home.resolvingSymlinksInPath().path
if let walker = manager.enumerator(at: home, includingPropertiesForKeys: nil) {
    var items: [URL] = []
    for case let url as URL in walker { items.append(url) }
    for url in items {
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(homePath + "/") else { continue }
        let relative = String(path.dropFirst(homePath.count + 1))
        let number = stableNumber(relative)
        let when = pinnedDates[relative] ?? day(4 + number % 40, 8 + number % 10, number % 60)
        try? manager.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
    }
}
print("demo home ready at \(home.path)")
