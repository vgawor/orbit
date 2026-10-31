import AppKit

/// Orbit as a menu bar icon: a single-colour template image (macOS tints it for light and dark
/// menu bars). Same shape as OrbitView: planet, ring tilted 24°, two eyes cut out.
enum OrbitMenuIcon {
    static let image: NSImage = {
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let u = rect.height / 104 * 1.02
            let center = CGPoint(x: rect.midX, y: rect.midY + 0.3)
            let rx = 47 * u, ry = 15 * u, line = 9 * u
            let tilt = 24 * CGFloat.pi / 180

            func frontArc() -> CGPath {
                let p = CGMutablePath()
                for i in 0...32 {
                    let a = CGFloat(i) / 32 * .pi
                    let pt = CGPoint(x: rx * cos(a), y: ry * sin(a))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            func inRing(_ draw: () -> Void) {
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                ctx.rotate(by: tilt)
                draw()
                ctx.restoreGState()
            }

            ctx.setFillColor(.black)
            ctx.setStrokeColor(.black)
            // Back of the ring.
            inRing {
                ctx.setLineWidth(line)
                ctx.strokeEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
            }
            // Body.
            ctx.fillEllipse(in: CGRect(x: center.x - 30 * u, y: center.y - 30 * u, width: 60 * u, height: 60 * u))
            // Eyes and a gap around the front of the ring are cut out, so the shapes read at 18 pt.
            ctx.setBlendMode(.clear)
            for e in [(4.0, -11.0), (18.0, -3.0)] {
                ctx.saveGState()
                ctx.translateBy(x: center.x + CGFloat(e.0) * u, y: center.y + CGFloat(e.1) * u)
                ctx.rotate(by: tilt)
                ctx.fillEllipse(in: CGRect(x: -5.2 * u, y: -7.2 * u, width: 10.4 * u, height: 14.4 * u))
                ctx.restoreGState()
            }
            inRing {
                ctx.addPath(frontArc())
                ctx.setLineWidth(line + 7 * u)
                ctx.strokePath()
            }
            ctx.setBlendMode(.normal)
            // Front of the ring.
            inRing {
                ctx.addPath(frontArc())
                ctx.setLineWidth(line)
                ctx.setLineCap(.round)
                ctx.strokePath()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Orbit"
        return img
    }()
}
