// Draws Nook's app icon, a smooth pebble on a sea-green tile, and writes a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// An organic stone: a squashed superellipse, slightly fuller at the bottom, tilted a few degrees.
func pebble(center: NSPoint, width: CGFloat, height: CGFloat, tilt: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 180
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        // An exponent above 2 squares the oval off a little, like a river stone.
        let n: CGFloat = 2.35
        // Fuller toward the bottom, blended smoothly so the outline has no seams.
        let fullness = 1 + 0.05 * max(0, -s)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1) * width / 2 * fullness
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1) * height / 2 * fullness
        let rotated = NSPoint(x: x * cos(tilt) - y * sin(tilt), y: x * sin(tilt) + y * cos(tilt))
        let point = NSPoint(x: center.x + rotated.x, y: center.y + rotated.y)
        step == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // macOS icon grid: an 824pt rounded square with a soft drop shadow.
    let tile = rect.insetBy(dx: 100, dy: 100)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x2E8C7A).setFill()
    tilePath.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [color(0x86D6BE), color(0x4FB39A), color(0x2A8573)])?.draw(in: tilePath, angle: -90)

    NSGraphicsContext.current?.saveGraphicsState()
    tilePath.addClip()

    let center = NSPoint(x: rect.midX, y: rect.midY + 6)
    let stone = pebble(center: center, width: 560, height: 420, tilt: -0.07)

    // Contact shadow, then the stone itself.
    NSGraphicsContext.current?.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = color(0x0D3D34, 0.5)
    drop.shadowBlurRadius = 60
    drop.shadowOffset = NSSize(width: 0, height: -34)
    drop.set()
    color(0xF2EEE4).setFill()
    stone.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [color(0xFFFFFF), color(0xF3EFE6), color(0xE1DACB)])?.draw(in: stone, angle: -80)

    // A soft highlight along the top edge.
    NSGraphicsContext.current?.saveGraphicsState()
    stone.addClip()
    let sheen = NSBezierPath(ovalIn: NSRect(x: center.x - 230, y: center.y + 60, width: 400, height: 190))
    NSGradient(colors: [color(0xFFFFFF, 0.9), color(0xFFFFFF, 0)])?.draw(in: sheen, relativeCenterPosition: NSPoint(x: -0.2, y: 0.3))
    NSGraphicsContext.current?.restoreGraphicsState()

    // The dimple: a shallow sea-green hollow. Shading at the top and a light rim at the bottom make it read as pressed in.
    let dimpleRect = NSRect(x: center.x - 58, y: center.y - 64, width: 116, height: 116)
    let dimple = NSBezierPath(ovalIn: dimpleRect)
    let rim = NSBezierPath(ovalIn: dimpleRect.insetBy(dx: -7, dy: -7).offsetBy(dx: 0, dy: -4))
    NSGradient(colors: [color(0xFFFFFF, 0), color(0xFFFFFF, 0.95)])?.draw(in: rim, angle: -90)
    NSGradient(colors: [color(0x3E9F89), color(0x6FCDB3)])?.draw(in: dimple, angle: -90)
    NSGraphicsContext.current?.saveGraphicsState()
    dimple.addClip()
    let inner = NSBezierPath(rect: dimpleRect.insetBy(dx: -40, dy: -40))
    inner.append(NSBezierPath(ovalIn: dimpleRect.offsetBy(dx: 0, dy: -8)))
    inner.windingRule = .evenOdd
    let innerShadow = NSShadow()
    innerShadow.shadowColor = color(0x0B3B33, 0.45)
    innerShadow.shadowBlurRadius = 14
    innerShadow.shadowOffset = NSSize(width: 0, height: -5)
    innerShadow.set()
    color(0x2E8C7A).setFill()
    inner.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.restoreGraphicsState()
    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Couldn't render the icon")
}
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
