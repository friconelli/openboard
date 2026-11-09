import AppKit
// OpenBoard app icon: a 2×2 board of rounded tiles, the last one a chat bubble, in sage on a
// near-black green background. Drawn full-bleed (no squircle, no margin): macOS 26 applies its
// own mask, while an icon with its own shape and transparent margin gets a grey plate around it.
// Usage: swift Scripts/draw_icon.swift Resources/AppIcon-1024.png
let size: CGFloat = 1024
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
let cg = context.cgContext

// Background: soft radial light from the top left, dark green-black at the edges.
let background = NSGradient(colors: [color(0x1F2521), color(0x141815), color(0x0D100E)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
background.draw(in: NSRect(x: 0, y: 0, width: size, height: size), relativeCenterPosition: NSPoint(x: -0.35, y: 0.45))

// Tiles.
let tile: CGFloat = 268, gap: CGFloat = 36, radius: CGFloat = 64
let origin = (size - (tile * 2 + gap)) / 2
let top = NSGradient(colors: [color(0x98BEA4), color(0x7FA88B), color(0x5F8B6C)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!

func tilePath(_ rect: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// Speech-bubble tail growing out of the bottom right of `rect` (it starts inside the tile, so
/// tile and tail read as one shape).
func tailPath(_ rect: NSRect) -> NSBezierPath {
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: rect.maxX - 132, y: rect.minY + 40))
    tail.line(to: NSPoint(x: rect.maxX - 30, y: rect.minY + 40))
    tail.line(to: NSPoint(x: rect.maxX - 30, y: rect.minY - 40))
    tail.curve(to: NSPoint(x: rect.maxX - 132, y: rect.minY + 40),
               controlPoint1: NSPoint(x: rect.maxX - 58, y: rect.minY - 18),
               controlPoint2: NSPoint(x: rect.maxX - 100, y: rect.minY + 4))
    tail.close()
    return tail
}

for row in 0..<2 {
    for column in 0..<2 {
        let rect = NSRect(x: origin + CGFloat(column) * (tile + gap),
                          y: origin + CGFloat(1 - row) * (tile + gap), width: tile, height: tile)
        let bubble = row == 1 && column == 1
        let path = bubble ? NSBezierPath(cgPath: tilePath(rect).cgPath.union(tailPath(rect).cgPath)) : tilePath(rect)
        // Drop shadow.
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        color(0x5F8B6C).setFill()
        path.fill()
        cg.restoreGState()
        // Face, lit from the top left; the bubble a touch deeper.
        cg.saveGState()
        path.addClip()
        top.draw(in: path.bounds.insetBy(dx: -40, dy: -40), angle: bubble ? -60 : -50)
        if bubble { color(0x2F5A3E, 0.18).setFill(); path.bounds.fill() }
        cg.restoreGState()
        // Fine highlight along the top edge and a soft inner rim.
        cg.saveGState()
        tilePath(rect).addClip()
        color(0xFFFFFF, 0.22).setStroke()
        let rim = tilePath(rect.offsetBy(dx: 0, dy: -3))
        rim.lineWidth = 6
        rim.stroke()
        cg.restoreGState()
    }
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("==> \(CommandLine.arguments[1])")
