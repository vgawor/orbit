// Draws the background of the release DMG window: a dark glassy wallpaper, "Drag Orbit to
// Applications", a dashed arrow from the app to the Applications folder with Orbit flying along it,
// and the Open Anyway help line. Writes dmg-background.png, @2x.png and a two-size .tiff.
// Run: swift scripts/make-dmg-background.swift <outdir>
//
// The layout must match scripts/dmg-settings.py: a 660×400 window, 128 px icons centred at
// (170, 188) and (490, 188), with Finder's labels just below them. Finder may treat 660×400 as the
// whole window including its title bar, so everything that matters stays in the top ~350 points.
import AppKit

let W: CGFloat = 660, H: CGFloat = 400
let appSpot = CGPoint(x: 170, y: 188), appsSpot = CGPoint(x: 490, y: 188)

func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

/// A soft round glow: a radial gradient fading to nothing (stands in for a blurred blob).
func glow(_ ctx: CGContext, at c: CGPoint, radius r: CGFloat, color: NSColor, alpha: CGFloat) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let stops: [CGFloat] = [0, 0.35, 0.7, 1]
    let colors = stops.map { s -> CGColor in
        let falloff = pow(1 - s, 2.2)
        return color.withAlphaComponent(alpha * falloff).cgColor
    } as CFArray
    let g = CGGradient(colorsSpace: space, colors: colors, locations: stops)!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}

/// Orbit, as in Viktor/Views/Orbit.swift: white planet, lilac ring tilted 24°, two tilted eyes.
/// Drawn in a 100×100 design space centred on `c`, `size` points wide. y grows downwards.
func drawOrbit(_ ctx: CGContext, center c: CGPoint, size: CGFloat, tilt: CGFloat) {
    let u = size / 104
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.rotate(by: tilt * .pi / 180)
    ctx.translateBy(x: -52 * u, y: -54 * u)  // design centre (50, 52) + 2 margin
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x + 2) * u, y: (y + 2) * u) }
    let center = pt(50, 52)
    let ring = rgb(0xB9B6D3), body = NSColor.white, eyes = rgb(0x16131F)
    let rx = 47 * u, ry = 15 * u, lw = 8.5 * u

    // Soft shadow under the whole character so it lifts off the wallpaper.
    ctx.setShadow(offset: CGSize(width: 0, height: 3 * u), blur: 10 * u, color: NSColor(white: 0, alpha: 0.45).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    func ringSpace(_ draw: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: 24 * .pi / 180)
        draw()
        ctx.restoreGState()
    }
    // Back of the ring.
    ringSpace {
        ctx.setStrokeColor(ring.cgColor); ctx.setLineWidth(lw)
        ctx.strokeEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
    }
    // Body.
    ctx.setFillColor(body.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - 30 * u, y: center.y - 30 * u, width: 60 * u, height: 60 * u))
    // Eyes, tilted with the ring.
    for e in [(54.0, 41.0), (68.0, 49.0)] {
        let p = pt(CGFloat(e.0), CGFloat(e.1))
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y); ctx.rotate(by: 24 * .pi / 180)
        ctx.setFillColor(eyes.cgColor)
        ctx.fillEllipse(in: CGRect(x: -4.6 * u, y: -6.4 * u, width: 9.2 * u, height: 12.8 * u))
        ctx.restoreGState()
    }
    // Front half of the ring, over the body (y down: the front is the lower half, sin > 0).
    ringSpace {
        let front = CGMutablePath()
        for i in 0...32 {
            let a = CGFloat(i) / 32 * .pi
            let p = CGPoint(x: rx * cos(a), y: ry * sin(a))
            if i == 0 { front.move(to: p) } else { front.addLine(to: p) }
        }
        ctx.addPath(front)
        ctx.setStrokeColor(ring.cgColor); ctx.setLineWidth(lw); ctx.setLineCap(.butt)
        ctx.strokePath()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: CGFloat, top: CGFloat, kern: CGFloat = 0) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style, .kern: kern]
    let str = NSAttributedString(string: s, attributes: attrs)
    let w = str.size().width + 4
    str.draw(in: NSRect(x: centerX - w / 2, y: top, width: w, height: size * 1.5))
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)  // points, so the 2x image carries 144 dpi
    NSGraphicsContext.saveGraphicsState()
    let ns = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ns
    let ctx = ns.cgContext
    // Work top-down in points, like the Finder window.
    // (the context already maps points to pixels, because rep.size is in points)
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

    // 1. Deep navy → purple base.
    let base = NSGradient(colors: [rgb(0x0B0A1A), rgb(0x120E2E), rgb(0x1A1035)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    base.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 70)

    // 2. Colour glows, like the app's wallpaper; kept off the icon spots so labels stay on dark.
    glow(ctx, at: CGPoint(x: 40, y: 420), radius: 330, color: rgb(0x5C3DF5), alpha: 0.9)
    glow(ctx, at: CGPoint(x: 640, y: -40), radius: 320, color: rgb(0xFF6B3D), alpha: 0.6)
    glow(ctx, at: CGPoint(x: 680, y: 420), radius: 300, color: rgb(0x1FB5FF), alpha: 0.65)
    glow(ctx, at: CGPoint(x: 330, y: 150), radius: 180, color: rgb(0x8A6BFF), alpha: 0.18)

    // 3. A faint glassy pane behind everything, with a hairline top edge.
    let pane = NSBezierPath(roundedRect: NSRect(x: 28, y: 84, width: W - 56, height: 228), xRadius: 26, yRadius: 26)
    ctx.saveGState()
    pane.addClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.07), NSColor(white: 1, alpha: 0.015)])!
        .draw(in: NSRect(x: 0, y: 84, width: W, height: 228), angle: -90)
    ctx.restoreGState()
    pane.lineWidth = 1
    NSColor(white: 1, alpha: 0.12).setStroke(); pane.stroke()

    // 4. Finder draws the icon labels in dark text on picture backgrounds, so each label sits on a
    //    light frosted pill (centred 87 pt below the icon centre, where Finder puts the label).
    for spot in [appSpot, appsSpot] {
        glow(ctx, at: CGPoint(x: spot.x, y: spot.y), radius: 100, color: rgb(0x05040C), alpha: 0.3)
        let pill = NSBezierPath(roundedRect: NSRect(x: spot.x - 62, y: spot.y + 87 - 12, width: 124, height: 24), xRadius: 12, yRadius: 12)
        NSColor(white: 1, alpha: 0.86).setFill(); pill.fill()
        NSColor(white: 1, alpha: 0.95).setStroke(); pill.lineWidth = 1; pill.stroke()
    }

    // 5. Title.
    text("Drag Orbit to Applications", size: 24, weight: .semibold, color: NSColor(white: 1, alpha: 0.95),
         centerX: W / 2, top: 24, kern: -0.2)
    text("to install it", size: 13, weight: .regular, color: NSColor(white: 1, alpha: 0.55), centerX: W / 2, top: 55)

    // 6. Curved dashed arrow, arching over the gap between the icons.
    let start = CGPoint(x: appSpot.x + 84, y: appSpot.y - 14)
    let end = CGPoint(x: appsSpot.x - 86, y: appsSpot.y - 14)
    let control = CGPoint(x: W / 2, y: appSpot.y - 74)
    let arc = CGMutablePath()
    arc.move(to: start); arc.addQuadCurve(to: end, control: control)
    ctx.saveGState()
    ctx.addPath(arc)
    ctx.setLineWidth(3); ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [0.1, 9])
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.8).cgColor)
    ctx.setShadow(offset: .zero, blur: 8, color: rgb(0x8A6BFF, 0.9).cgColor)
    ctx.strokePath()
    ctx.restoreGState()
    // Arrow head, along the curve's end tangent.
    let tangent = CGPoint(x: end.x - control.x, y: end.y - control.y)
    let ang = atan2(tangent.y, tangent.x)
    let head = CGMutablePath()
    let len: CGFloat = 13, spread: CGFloat = 0.55
    head.move(to: CGPoint(x: end.x - len * cos(ang - spread), y: end.y - len * sin(ang - spread)))
    head.addLine(to: end)
    head.addLine(to: CGPoint(x: end.x - len * cos(ang + spread), y: end.y - len * sin(ang + spread)))
    ctx.saveGState()
    ctx.addPath(head)
    ctx.setLineWidth(3); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
    ctx.setShadow(offset: .zero, blur: 8, color: rgb(0x8A6BFF, 0.9).cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    // 7. Orbit riding the arrow, a little past the top, with a short motion trail behind it.
    func onCurve(_ t: CGFloat) -> CGPoint {
        let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
        return CGPoint(x: a * start.x + b * control.x + c * end.x, y: a * start.y + b * control.y + c * end.y)
    }
    let tOrbit: CGFloat = 0.5
    for (i, t) in [0.29, 0.36, 0.43].enumerated() {
        let p = onCurve(CGFloat(t))
        let r = CGFloat(2 + i)
        ctx.setFillColor(rgb(0xFFB08F, 0.35 + 0.2 * CGFloat(i)).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r - 1, width: r * 2, height: r * 2))
    }
    let op = onCurve(tOrbit)
    glow(ctx, at: op, radius: 46, color: rgb(0xFF6B3D), alpha: 0.35)
    drawOrbit(ctx, center: CGPoint(x: op.x, y: op.y - 2), size: 54, tilt: 8)

    // 8. Help for the not-notarized build, quiet at the bottom.
    text("If macOS blocks Orbit: System Settings → Privacy & Security → Open Anyway",
         size: 11.5, weight: .regular, color: NSColor(white: 1, alpha: 0.5), centerX: W / 2, top: 326)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "build/dmg-background", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let one = out.appendingPathComponent("dmg-background.png")
let two = out.appendingPathComponent("dmg-background@2x.png")
try render(scale: 1).representation(using: .png, properties: [:])!.write(to: one)
try render(scale: 2).representation(using: .png, properties: [:])!.write(to: two)

// One TIFF with both sizes, so Finder picks the sharp one on Retina.
let tiff = out.appendingPathComponent("dmg-background.tiff")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
p.arguments = ["-cathidpicheck", one.path, two.path, "-out", tiff.path]
p.standardOutput = FileHandle.nullDevice
p.standardError = FileHandle.nullDevice
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("tiffutil failed") }
print("DMG background written to \(out.path)")
