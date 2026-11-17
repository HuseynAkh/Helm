// MARK: The comparison sheet
// usage: swift sheet.swift <app-icon.icns> <out-dir>

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func sheet(_ marks: [Mark], iconPath: String, outDir: String, name: String = "sheet.png") {
    guard let icon = NSImage(contentsOfFile: iconPath) else {
        FileHandle.standardError.write(Data("can't read \(iconPath)\n".utf8)); exit(1)
    }
    var iconRect = CGRect(x: 0, y: 0, width: 192, height: 192)
    let iconImage = icon.cgImage(forProposedRect: &iconRect, context: nil, hints: nil)!

    let scale: CGFloat = 2
    let margin: CGFloat = 24, headerH: CGFloat = 40, rowH: CGFloat = 136, labelW: CGFloat = 170, gapX: CGFloat = 10
    let columns: [(String, CGFloat)] = [("16 pt at rest", 84), ("16 pt lit", 84), ("22 pt lit, search field", 210),
                                        ("64 pt on white", 116), ("64 pt on #1E1E1E", 116),
                                        ("Banner: icon 96 pt, mark 72 pt", 290)]
    let width = margin * 2 + labelW + columns.map(\.1).reduce(0, +) + gapX * CGFloat(columns.count)
    let height = margin * 2 + headerH + rowH * CGFloat(marks.count)
    let context = makeContext(width: Int(width * scale), height: Int(height * scale))
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(rgb(0xF5F5F7)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    func text(_ s: String, _ p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = NSColor(white: 0.35, alpha: 1)) {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: p)
    }
    func box(_ r: CGRect, _ color: CGColor, radius: CGFloat = 10, edge: CGColor? = nil) {
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path); context.setFillColor(color); context.fillPath()
        if let edge { context.addPath(path); context.setStrokeColor(edge); context.setLineWidth(1); context.strokePath() }
    }
    /// The mark drawn as its own bitmap and placed on whole device pixels, as a button image would be.
    func put(_ mark: Mark, size: CGFloat, center: CGPoint, paint: Paint) {
        let image = markImage(mark, size: size, scale: scale, paint: paint)
        let origin = CGPoint(x: ((center.x - size / 2) * scale).rounded() / scale, y: ((center.y - size / 2) * scale).rounded() / scale)
        context.draw(image, in: CGRect(origin: origin, size: CGSize(width: size, height: size)))
    }

    var x = margin + labelW
    let top = height - margin
    for (title, w) in columns {
        text(title, CGPoint(x: x + 2, y: top - 22), size: 11, weight: .medium)
        x += w + gapX
    }
    let header = rgb(0xEBEBEB)
    for (row, mark) in marks.enumerated() {
        let y0 = top - headerH - rowH * CGFloat(row + 1) + 8
        let h = rowH - 16
        let midY = y0 + h / 2
        text(mark.letter, CGPoint(x: margin + 4, y: midY - 6), size: 30, weight: .bold, color: NSColor(white: 0.12, alpha: 1))
        text(mark.name, CGPoint(x: margin + 6, y: midY - 26), size: 13, weight: .medium, color: NSColor(white: 0.25, alpha: 1))
        var cx = margin + labelW
        let cols = columns.map(\.1)
        // 16 pt at rest and lit, on the header's light grey.
        for (k, paint) in [Paint.plain(CGColor(gray: 0, alpha: 0.85)), Paint.lit(turn: 0)].enumerated() {
            let r = CGRect(x: cx, y: y0, width: cols[k], height: h)
            box(r, header, edge: rgb(0xD6D6D6))
            put(mark, size: 16, center: CGPoint(x: r.midX, y: r.midY), paint: paint)
            cx += cols[k] + gapX
        }
        // 22 pt lit in a search-field-like box.
        do {
            let r = CGRect(x: cx, y: y0, width: cols[2], height: h)
            box(r, header, edge: rgb(0xD6D6D6))
            let field = CGRect(x: r.minX + 14, y: r.midY - 16, width: r.width - 28, height: 32)
            box(field, rgb(0xFFFFFF), radius: 8, edge: rgb(0xC9C9C9))
            put(mark, size: 22, center: CGPoint(x: field.minX + 5 + 11, y: field.midY), paint: .lit(turn: 0))
            text("Search", CGPoint(x: field.minX + 34, y: field.midY - 8), size: 13, color: NSColor(white: 0.55, alpha: 1))
            cx += cols[2] + gapX
        }
        // 64 pt on white and on dark.
        for (k, bg) in [(3, rgb(0xFFFFFF)), (4, rgb(0x1E1E1E))] {
            let r = CGRect(x: cx, y: y0, width: cols[k], height: h)
            box(r, bg, edge: rgb(0xD6D6D6))
            put(mark, size: 64, center: CGPoint(x: r.midX, y: r.midY), paint: .lit(turn: 0))
            cx += cols[k] + gapX
        }
        // The banner: the app icon at 96 pt with the mark beside it at 72 pt.
        do {
            let r = CGRect(x: cx, y: y0, width: cols[5], height: h)
            context.saveGState()
            context.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.clip()
            let bg = CGGradient(colorsSpace: sRGB, colors: [rgb(0xFFFFFF), rgb(0xF4F1EC)] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(bg, start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
            context.restoreGState()
            box(r, rgb(0, 0), edge: rgb(0xD6D6D6))
            let iconFrame = CGRect(x: r.minX + 40, y: r.midY - 48, width: 96, height: 96)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: CGColor(gray: 0, alpha: 0.25))
            context.draw(iconImage, in: iconFrame)
            context.restoreGState()
            put(mark, size: 72, center: CGPoint(x: iconFrame.maxX + 28 + 36, y: r.midY), paint: .lit(turn: 0))
        }
    }
    let image = context.makeImage()!
    writePNG(image, to: outDir + "/" + name)

    // A close look at the small sizes: each mark at 16 pt (at rest and lit) and 22 pt (lit), drawn at 2x and then
    // enlarged four times without smoothing, so every device pixel can be checked.
    let z: CGFloat = 4
    let cell: CGFloat = 26 * scale * z
    let looks: [(CGFloat, Paint, CGColor)] = [(16, .plain(CGColor(gray: 0, alpha: 0.85)), header), (16, .lit(turn: 0), header),
                                              (22, .lit(turn: 0), rgb(0xFFFFFF)), (16, .lit(turn: 0), rgb(0x1E1E1E))]
    let zoom = makeContext(width: Int(cell) * looks.count, height: Int(cell) * marks.count)
    zoom.interpolationQuality = .none
    for (row, mark) in marks.enumerated() {
        for (k, (size, paint, bg)) in looks.enumerated() {
            let r = CGRect(x: cell * CGFloat(k), y: cell * CGFloat(marks.count - 1 - row), width: cell, height: cell)
            zoom.setFillColor(bg); zoom.fill(r)
            let side = size * scale * z
            zoom.draw(markImage(mark, size: size, scale: scale, paint: paint),
                      in: CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side))
        }
    }
    writePNG(zoom.makeImage()!, to: outDir + "/zoom-small.png")
}
