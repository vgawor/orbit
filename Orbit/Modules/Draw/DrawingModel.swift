import AppKit
import SwiftUI

// The plain data behind screen drawing: which tool, which color, how thick, and the marks themselves.

/// What a drag on the screen does.
enum DrawingTool: String, CaseIterable, Identifiable {
    case pen, highlighter, arrow, rectangle, eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: "Pen (P)"
        case .highlighter: "Highlighter (H)"
        case .arrow: "Arrow (A)"
        case .rectangle: "Rectangle (R)"
        case .eraser: "Eraser (E)"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .eraser: "eraser"
        }
    }
}

/// The six ink colors, in the order of the 1–6 keys.
enum DrawingPalette {
    static let colors: [NSColor] = [
        NSColor(red: 1.0, green: 0.271, blue: 0.227, alpha: 1),   // red    #FF453A
        NSColor(red: 1.0, green: 0.839, blue: 0.039, alpha: 1),   // yellow #FFD60A
        NSColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1), // green  #34C759
        NSColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1),   // blue   #0A84FF
        .white,
        .black,
    ]
    static let names = ["Red", "Yellow", "Green", "Blue", "White", "Black"]
}

/// The three line widths you can pick (in points, for the pen).
enum DrawingWidths {
    static let all: [CGFloat] = [3, 6, 12]
}

/// One finished (or in-progress) mark on one screen.
struct Stroke {
    let tool: DrawingTool
    let color: NSColor
    let width: CGFloat
    /// Every point the mouse passed through. Arrows and rectangles only use the first and last.
    var points: [CGPoint]

    /// Highlighter marks are wide and see-through, so the text below still shows.
    var drawWidth: CGFloat { tool == .highlighter ? width * 3.5 : width }
    var drawColor: NSColor { tool == .highlighter ? color.withAlphaComponent(0.35) : color }

    /// The shape to stroke for this mark (not including an arrow's head, see `arrowHead`).
    var path: CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        let last = points.last ?? first

        switch tool {
        case .arrow:
            path.move(to: first)
            path.addLine(to: last)
        case .rectangle:
            path.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                width: abs(last.x - first.x), height: abs(last.y - first.y)))
        case .pen, .highlighter, .eraser:
            // Smooth freehand line: curve through the midpoints between samples,
            // using each real sample as the curve's control point. Hides mouse jitter.
            path.move(to: first)
            if points.count < 3 {
                path.addLine(to: last)
            } else {
                for i in 1..<points.count {
                    let a = points[i - 1], b = points[i]
                    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    path.addQuadCurve(to: mid, control: a)
                }
                path.addLine(to: last)
            }
        }
        return path
    }

    /// Filled triangle at the end of an arrow. Nil for other tools or a zero-length drag.
    var arrowHead: CGPath? {
        guard tool == .arrow, let start = points.first, let end = points.last else { return nil }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 2 else { return nil }

        let angle = atan2(dy, dx)
        let headLength = max(14, width * 4)
        let spread: CGFloat = .pi / 7
        let left = CGPoint(x: end.x - headLength * cos(angle - spread), y: end.y - headLength * sin(angle - spread))
        let right = CGPoint(x: end.x - headLength * cos(angle + spread), y: end.y - headLength * sin(angle + spread))

        let head = CGMutablePath()
        head.move(to: end)
        head.addLine(to: left)
        head.addLine(to: right)
        head.closeSubpath()
        return head
    }

    /// True if `point` is on (or very near) this mark. Used by the eraser.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let outline = path.copy(strokingWithWidth: drawWidth + tolerance * 2,
                                lineCap: .round, lineJoin: .round, miterLimit: 10)
        if outline.contains(point) { return true }
        return arrowHead?.contains(point) ?? false
    }
}
