// Draws Orbit's app icon (Orbit the planet on a dark glass squircle) and writes the iconset.
// Run: swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
// Orbit's shape matches OrbitView in Orbit/Views/Orbit.swift (a 104-unit grid, ring tilted 24°).
import AppKit

func rgb(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

/// Orbit in a square `box`, in a y-down context.
func drawOrbit(_ ctx: CGContext, in box: CGRect, body: CGColor, ring: CGColor, eyes: CGColor) {
    let u = box.width / 104
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + (x + 2) * u, y: box.minY + (y + 2) * u) }
    let center = pt(50, 52)
    let rx = 47 * u, ry = 15 * u, line = 8.5 * u

    func strokeRing(_ front: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: 24 * .pi / 180)
        ctx.setStrokeColor(ring)
        ctx.setLineWidth(line)
        if front {
            // Half ellipse in front of the body (the lower half in y-down).
            let path = CGMutablePath()
            for i in 0...48 {
                let a = CGFloat(i) / 48 * .pi
                let p = CGPoint(x: rx * cos(a), y: ry * sin(a))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.addPath(path)
            ctx.setLineCap(.butt)
            ctx.strokePath()
        } else {
            ctx.strokeEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
        }
        ctx.restoreGState()
    }

    strokeRing(false)
    ctx.setFillColor(body)
    ctx.fillEllipse(in: CGRect(x: center.x - 30 * u, y: center.y - 30 * u, width: 60 * u, height: 60 * u))
    for e in [(54.0, 41.0), (68.0, 49.0)] {
        let c = pt(CGFloat(e.0), CGFloat(e.1))
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: 24 * .pi / 180)
        ctx.setFillColor(eyes)
        ctx.fillEllipse(in: CGRect(x: -4.6 * u, y: -6.4 * u, width: 9.2 * u, height: 12.8 * u))
        ctx.restoreGState()
    }
    strokeRing(true)
}

func draw(_ size: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // y-down, like SwiftUI.
    ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)
    let tile = CGRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
    let shape = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)

    // Background: deep night gradient with soft colour glows (the website's palette).
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x1B1440), rgb(0x0B0918)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.midX, y: tile.minY), end: CGPoint(x: tile.midX, y: tile.maxY), options: [])
    func glow(_ c: UInt32, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a: CGFloat) {
        let g = CGGradient(colorsSpace: space, colors: [rgb(c, a), rgb(c, 0)] as CFArray, locations: [0, 1])!
        let p = CGPoint(x: tile.minX + tile.width * x, y: tile.minY + tile.height * y)
        ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: tile.width * r, options: [])
    }
    glow(0x5C3DF5, 0.15, 0.95, 0.75, 0.85)
    glow(0xFF6B3D, 0.95, 0.05, 0.55, 0.55)
    glow(0x1FB5FF, 0.95, 0.95, 0.5, 0.45)
    // A few stars.
    for (x, y, r) in [(0.18, 0.2, 0.012), (0.78, 0.3, 0.009), (0.3, 0.82, 0.008), (0.86, 0.72, 0.011), (0.62, 0.14, 0.007)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.75))
        let s = tile.width * r
        ctx.fillEllipse(in: CGRect(x: tile.minX + tile.width * x - s, y: tile.minY + tile.height * y - s, width: s * 2, height: s * 2))
    }
    // Light rim along the top, like glass.
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    ctx.setLineWidth(max(1, size * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    // Orbit, with a soft glow behind it.
    let box = tile.insetBy(dx: tile.width * 0.1, dy: tile.width * 0.1)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.05, color: rgb(0xA196FC, 0.55))
    drawOrbit(ctx, in: box, body: rgb(0xFFFFFF), ring: rgb(0xB9B6D3), eyes: rgb(0x16131F))
    ctx.restoreGState()
    return ctx.makeImage()!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: set)
try fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(cgImage: draw(px))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
print("iconset written")
