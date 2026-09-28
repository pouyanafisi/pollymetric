import AppKit

/// The Pollymetric mark, drawn from the same geometry as `design/logo.svg` so it
/// stays a crisp vector at any size (menu bar, retina, app icon).
///
/// Two half-rings meet at x = 274 (SVG units, y down). The left one is larger by half
/// the 72-unit stroke, so both tops align and the right ring's outer end lands exactly
/// on the left ring's inner end, stepping the stroke down into the p's tail.
enum LogoMark {
    /// The mark's bounds in SVG units (x 88…460 would include padding; this is the ink).
    static let bounds = CGRect(x: 88, y: 70, width: 336, height: 372)

    /// The mark in SVG units, for a flipped (y-down) context.
    static var path: NSBezierPath {
        let p = NSBezierPath()
        // Right half-ring: centre (274, 220), outer 150, inner 78, top → right → bottom.
        p.move(to: CGPoint(x: 274, y: 70))
        p.appendArc(withCenter: CGPoint(x: 274, y: 220), radius: 150, startAngle: 270, endAngle: 90, clockwise: false)
        p.line(to: CGPoint(x: 274, y: 298))
        p.appendArc(withCenter: CGPoint(x: 274, y: 220), radius: 78, startAngle: 90, endAngle: 270, clockwise: true)
        p.close()
        // Left half-ring: centre (274, 256), outer 186, inner 114, top → left → bottom.
        p.move(to: CGPoint(x: 274, y: 70))
        p.appendArc(withCenter: CGPoint(x: 274, y: 256), radius: 186, startAngle: 270, endAngle: 90, clockwise: true)
        p.line(to: CGPoint(x: 274, y: 370))
        p.appendArc(withCenter: CGPoint(x: 274, y: 256), radius: 114, startAngle: 90, endAngle: 270, clockwise: false)
        p.close()
        // The dot.
        p.appendOval(in: CGRect(x: 250 - 29, y: 231 - 29, width: 58, height: 58))
        return p
    }

    /// The mark fitted into a square of `size` points. With no color it's a template
    /// image, so macOS tints it to match the menu bar (light, dark, highlighted).
    static func image(size: CGFloat, color: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let scale = min(rect.width / bounds.width, rect.height / bounds.height)
            let transform = NSAffineTransform()
            transform.translateX(
                by: rect.midX - bounds.midX * scale,
                yBy: rect.midY - bounds.midY * scale
            )
            transform.scale(by: scale)
            let path = self.path
            path.transform(using: transform as AffineTransform)
            (color ?? .black).setFill()
            path.fill()
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "Pollymetric"
        return image
    }

    /// The app icon: the mark on a light rounded square, laid out on Apple's icon grid
    /// (824 of 1024 units for the body, 185 corner radius, soft drop shadow). Finder, the
    /// Dock, System Settings (Full Disk Access, Login Items) and alerts all show this.
    static func appIcon(pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        let unit = CGFloat(pixels) / 1024
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        let cg = context.cgContext
        // Flip to y-down so the mark's SVG coordinates apply directly.
        cg.translateBy(x: 0, y: CGFloat(pixels))
        cg.scaleBy(x: 1, y: -1)

        let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * unit, yRadius: 185 * unit)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 18 * unit
        // Shadow offsets live in device space and ignore the flip above: negative is down.
        shadow.shadowOffset = NSSize(width: 0, height: -8 * unit)
        shadow.set()
        NSColor(white: 0.965, alpha: 1).setFill()
        squircle.fill()
        NSGraphicsContext.restoreGraphicsState()

        // A faint top-to-bottom sheen, like the reference's paper background.
        NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: 0.93, alpha: 1)])?
            .draw(in: squircle, angle: 90)
        NSColor.black.withAlphaComponent(0.08).setStroke()
        squircle.lineWidth = 1.5 * unit
        squircle.stroke()

        // The mark fills about 56% of the body height, centred.
        let markHeight = 824 * unit * 0.56
        let scale = markHeight / bounds.height
        let transform = NSAffineTransform()
        transform.translateX(by: body.midX - bounds.midX * scale, yBy: body.midY - bounds.midY * scale)
        transform.scale(by: scale)
        let mark = path
        mark.transform(using: transform as AffineTransform)
        NSColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1).setFill()
        mark.fill()
        return rep
    }

    /// Writes an .iconset folder (every size macOS asks for) for `iconutil`.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                guard let png = appIcon(pixels: points * scale)?.representation(using: .png, properties: [:]) else { continue }
                try png.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}
