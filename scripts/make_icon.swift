import AppKit

// Renders the PowerTelemetry app icon at all required sizes into AppIcon.iconset.
// Usage: swift scripts/make_icon.swift
// Design: authored bolt glyph (same geometry as the in-app wordmark), system-orange
// gradient, on a charcoal squircle following Apple's macOS icon grid (824pt artwork
// on a 1024pt canvas, transparent corners, no baked shadow).

func hexColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    // Squircle per Apple grid: artwork ≈ 80.5% of canvas, corner radius ≈ 22.37% of side
    let inset = size * 0.098
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Background: vertical charcoal gradient
    NSGradient(colors: [hexColor(0x262e36), hexColor(0x0d1114)])!
        .draw(in: squircle, angle: -90)

    // Hairline inner highlight for definition on dark backgrounds
    NSColor.white.withAlphaComponent(0.10).setStroke()
    let inner = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.001, dy: size * 0.001),
                             xRadius: radius, yRadius: radius)
    inner.lineWidth = max(size / 512, 1)
    inner.stroke()

    // Bolt glyph — same path as the wordmark SVG (viewBox 0 0 16 16, y flipped for AppKit)
    let unit: [(CGFloat, CGFloat)] = [
        (9, 15), (3, 7), (7, 7), (6, 1), (12, 9), (8, 9),
    ]
    let boltTargetH = rect.height * 0.56
    let scale = boltTargetH / 14 // glyph spans y 1…15
    let glyphW = 9 * scale       // glyph spans x 3…12
    let origin = CGPoint(x: rect.midX - glyphW / 2 - 3 * scale,
                         y: rect.midY - boltTargetH / 2 - 1 * scale)
    let bolt = NSBezierPath()
    bolt.move(to: CGPoint(x: origin.x + unit[0].0 * scale, y: origin.y + unit[0].1 * scale))
    for p in unit.dropFirst() {
        bolt.line(to: CGPoint(x: origin.x + p.0 * scale, y: origin.y + p.1 * scale))
    }
    bolt.close()
    bolt.lineJoinStyle = .round

    // Soft drop shadow for depth, then orange gradient fill
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = size * 0.012
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.006)
    shadow.set()
    NSGradient(colors: [hexColor(0xf7c14b), hexColor(0xd9762c)])!
        .draw(in: bolt, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    img.unlockFocus()
    return img
}

func savePNG(_ img: NSImage, to path: String) {
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed for \(path)")
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

// MARK: - Generate iconset

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = "\(root)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// (points, scale) pairs required by iconutil
let specs: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for (points, scale) in specs {
    let px = CGFloat(points * scale)
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    savePNG(drawIcon(size: px), to: "\(iconset)/\(name)")
    print("rendered \(name) (\(Int(px))px)")
}
print("iconset ready → \(iconset)")
