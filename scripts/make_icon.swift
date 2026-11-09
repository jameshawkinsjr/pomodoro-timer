// Renders Resources/AppIcon.icns from the shared tomato drawing.
// Run via scripts/make_icon.sh.
import AppKit

@main
enum MakeIcon {
    static func main() throws {
        let output = CommandLine.arguments[1]
        let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.removeItem(at: iconset)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 1 ? "" : "@2x"
                let png = try render(pixels: points * scale)
                try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }

        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
        try iconutil.run()
        iconutil.waitUntilExit()
        guard iconutil.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func render(pixels: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw CocoaError(.coderInvalidValue) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Draw in a 1024-unit space regardless of output size.
        let scale = CGFloat(pixels) / 1024
        NSAffineTransform(transform: { let t = NSAffineTransform(); t.scale(by: scale); return t }() as AffineTransform).concat()
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
        return data
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    static func drawIcon() {
        // Background tile on Apple's standard 824pt grid, with a soft drop shadow.
        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.shadowBlurRadius = 24
        shadow.set()
        color(0xFFF4E4).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: color(0xFFF8EE), ending: color(0xF7E2C4))?.draw(in: tile, angle: -90)

        let tomato = NSRect(x: 222, y: 190, width: 580, height: 580)
        let body = TomatoIcon.bodyPath(in: tomato)

        NSGraphicsContext.saveGraphicsState()
        let bodyShadow = NSShadow()
        bodyShadow.shadowColor = NSColor(srgbRed: 0.45, green: 0.08, blue: 0.05, alpha: 0.35)
        bodyShadow.shadowOffset = NSSize(width: 0, height: -14)
        bodyShadow.shadowBlurRadius = 22
        bodyShadow.set()
        color(0xD93025).setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colors: [color(0xFF7A66), color(0xE8382A), color(0xA81E16)])?
            .draw(in: body, relativeCenterPosition: NSPoint(x: -0.35, y: 0.35))

        // Glossy highlight.
        NSColor.white.withAlphaComponent(0.35).setFill()
        let highlight = NSBezierPath(ovalIn: NSRect(x: tomato.minX + 95, y: tomato.minY + 270, width: 120, height: 80))
        let rotate = NSAffineTransform()
        rotate.translateX(by: tomato.minX + 155, yBy: tomato.minY + 310)
        rotate.rotate(byDegrees: 35)
        rotate.translateX(by: -(tomato.minX + 155), yBy: -(tomato.minY + 310))
        highlight.transform(using: rotate as AffineTransform)
        highlight.fill()

        let leaves = TomatoIcon.leavesPath(in: tomato)
        leaves.lineWidth = 10
        leaves.lineJoinStyle = .round
        color(0x2E7D32).setStroke()
        leaves.stroke()
        NSGradient(starting: color(0x66BB6A), ending: color(0x2E7D32))?.draw(in: leaves, angle: -90)
    }
}
