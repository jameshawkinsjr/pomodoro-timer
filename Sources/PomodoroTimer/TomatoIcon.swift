import AppKit

/// Draws the tomato used for the menu bar icon and (via scripts/make_icon.swift) the app icon.
enum TomatoIcon {
    /// Menu bar icon: a monochrome template tomato when idle, a red tomato with green leaves when active.
    static func menuBarImage(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let inset = rect.insetBy(dx: 0.5, dy: 0.5)
            if active {
                draw(in: inset, body: .systemRed, leaves: .systemGreen)
            } else {
                draw(in: inset, body: .black, leaves: .black)
            }
            return true
        }
        // Template images adapt to light/dark menu bars; the active state keeps its colours.
        image.isTemplate = !active
        image.accessibilityDescription = active ? "Pomodoro Timer active" : "Pomodoro Timer inactive"
        return image
    }

    /// Flat two-colour tomato, with a transparent gap separating the leaves from the body.
    static func draw(in rect: NSRect, body: NSColor, leaves: NSColor) {
        body.setFill()
        bodyPath(in: rect).fill()

        let leafPath = leavesPath(in: rect)
        if let context = NSGraphicsContext.current {
            context.saveGraphicsState()
            context.compositingOperation = .destinationOut
            leafPath.lineWidth = rect.width * 0.1
            leafPath.lineJoinStyle = .round
            NSColor.black.set()
            leafPath.fill()
            leafPath.stroke()
            context.restoreGraphicsState()
        }

        leaves.setFill()
        leafPath.fill()
    }

    static func bodyPath(in rect: NSRect) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(
            x: rect.minX + rect.width * 0.04,
            y: rect.minY + rect.height * 0.02,
            width: rect.width * 0.92,
            height: rect.height * 0.78
        ))
    }

    /// A flattened five-pointed calyx plus a short stem, sitting on top of the body.
    static func leavesPath(in rect: NSRect) -> NSBezierPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }

        let center = (x: 0.5, y: 0.78)
        let outer: CGFloat = 0.3, inner: CGFloat = 0.14, squash: CGFloat = 0.55
        let path = NSBezierPath()
        for i in 0..<10 {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let radius = i.isMultiple(of: 2) ? outer : inner
            let p = point(center.x + radius * cos(angle), center.y + radius * sin(angle) * squash)
            i == 0 ? path.move(to: p) : path.line(to: p)
        }
        path.close()

        let stemOrigin = point(0.455, 0.76)
        let stemTop = point(0.545, 0.98)
        path.append(NSBezierPath(
            roundedRect: NSRect(x: stemOrigin.x, y: stemOrigin.y, width: stemTop.x - stemOrigin.x, height: stemTop.y - stemOrigin.y),
            xRadius: rect.width * 0.04,
            yRadius: rect.width * 0.04
        ))
        return path
    }
}
