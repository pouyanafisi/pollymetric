import AppKit

/// The DMG window's background, drawn from the same geometry as the icon so the brand
/// stays in one place. Laid out for a 660×400 window with 128-pt icons at (170, 190)
/// and (490, 190); keep `Support/dmg-settings.py` in step if these change.
enum InstallerArt {
    static let size = NSSize(width: 660, height: 400)

    /// Writes background.png (1×) and background@2x.png for `tiffutil -cathidpicheck`.
    static func writeDMGBackground(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for scale in [1, 2] {
            guard let png = render(scale: CGFloat(scale))?.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: dir.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png"))
        }
    }

    static func render(scale: CGFloat) -> NSBitmapImageRep? {
        let pixels = NSSize(width: size.width * scale, height: size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size // points, so Finder shows the 2× rep on retina displays
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        let cg = context.cgContext
        // rep.size is in points, so the context already maps points to pixels.
        // y-down, like Finder's icon coordinates.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)

        // Paper background with the faintest vertical sheen, like the logo's reference.
        NSGradient(colors: [NSColor(white: 0.975, alpha: 1), NSColor(white: 0.945, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: 90)

        // The arrow between the two icons: a thin line with an open chevron head.
        let ink = NSColor(white: 0.0, alpha: 0.28)
        ink.setStroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 262, y: 190))
        arrow.line(to: NSPoint(x: 394, y: 190))
        arrow.move(to: NSPoint(x: 382, y: 180))
        arrow.line(to: NSPoint(x: 396, y: 190))
        arrow.line(to: NSPoint(x: 382, y: 200))
        arrow.lineWidth = 2.2
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()

        // One instruction, centred under the icon labels.
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        func draw(_ text: String, y: CGFloat, size fontSize: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
            // Text draws upright in a flipped context only with NSGraphicsContext's flipped flag;
            // draw it in an unflipped sub-context instead.
            cg.saveGState()
            cg.translateBy(x: 0, y: y)
            cg.scaleBy(x: 1, y: -1)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
                .foregroundColor: NSColor(white: 0.08, alpha: alpha),
                .paragraphStyle: style,
                .kern: 0.1,
            ]
            (text as NSString).draw(in: NSRect(x: 40, y: -fontSize * 1.4, width: size.width - 80, height: fontSize * 1.6),
                                    withAttributes: attributes)
            cg.restoreGState()
        }
        draw("Drag Pollymetric to Applications to install", y: 318, size: 15, weight: .semibold, alpha: 0.85)
        draw("Then open it from Applications. It lives in your menu bar.", y: 342, size: 12.5, weight: .regular, alpha: 0.5)
        return rep
    }

    /// The repository's social preview (what a shared link shows): the icon, the name,
    /// the one-line promise, and the real menu bar panel. 1280×640, as GitHub asks.
    static func socialPreview(panel: NSImage, scale: CGFloat) -> NSBitmapImageRep? {
        let canvas = NSSize(width: 1280, height: 640)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context

        NSGradient(colors: [NSColor(white: 0.975, alpha: 1), NSColor(white: 0.93, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: canvas), angle: -90)

        // Left: icon, name, promise. (Unflipped coordinates: y grows upward.)
        if let icon = LogoMark.appIcon(pixels: 512) {
            let image = NSImage(size: NSSize(width: 136, height: 136)); image.addRepresentation(icon)
            image.draw(in: NSRect(x: 84, y: 400, width: 136, height: 136))
        }
        func text(_ string: String, x: CGFloat, top: CGFloat, width: CGFloat, size: CGFloat,
                  weight: NSFont.Weight, alpha: CGFloat, lineHeight: CGFloat = 1.18) {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = lineHeight
            let attributed = NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: NSColor(white: 0.07, alpha: alpha),
                .paragraphStyle: style,
            ])
            let bounds = attributed.boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin])
            attributed.draw(with: NSRect(x: x, y: top - bounds.height, width: width, height: bounds.height),
                            options: [.usesLineFragmentOrigin])
        }
        text("Pollymetric", x: 96, top: 384, width: 640, size: 64, weight: .bold, alpha: 0.95, lineHeight: 1.0)
        text("Is your Mac OK, and is there anything you should do?", x: 98, top: 290, width: 600,
             size: 34, weight: .semibold, alpha: 0.85)
        text("See what's slowing it down, catch what keeps coming back, and let your AI agent fix it. Right in your menu bar.",
             x: 98, top: 176, width: 590, size: 22, weight: .regular, alpha: 0.55, lineHeight: 1.3)

        // Right: the real panel, with a soft shadow.
        let height: CGFloat = 560
        let width = panel.size.width / panel.size.height * height
        let frame = NSRect(x: 1280 - width - 84, y: (640 - height) / 2, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        let clip = NSBezierPath(roundedRect: frame, xRadius: 18, yRadius: 18)
        NSColor.white.setFill(); clip.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        panel.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.08).setStroke()
        clip.lineWidth = 1
        clip.stroke()
        return rep
    }
}

