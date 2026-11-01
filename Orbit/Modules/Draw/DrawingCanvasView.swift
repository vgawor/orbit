import AppKit

/// See-through, borderless window that covers one whole screen and holds that screen's marks.
final class DrawingOverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above Orbit's notch panel (.statusBar + 1), so marks can go anywhere, even over the menu bar.
        level = DrawingOverlayWindow.overlayLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        // Saying "false" out loud makes the window catch clicks even where it's fully transparent.
        ignoresMouseEvents = false
        setFrame(screen.frame, display: false)
    }

    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

    // Borderless windows can't take keys unless they say so. We need Esc, ⌘Z, P/H/A, 1–6.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws one screen's marks and turns mouse drags into new marks.
final class DrawingCanvasView: NSView {
    /// Where the current tool, color and width come from, and where undo steps go.
    weak var controller: DrawingController?

    /// Finished marks on this screen, oldest first.
    private(set) var strokes: [Stroke] = []
    /// The mark being drawn right now, if the mouse is down.
    private var current: Stroke?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    // The first click should draw, not just focus the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Editing (used by the controller for undo / clear)

    func append(_ stroke: Stroke) { strokes.append(stroke); needsDisplay = true }

    func insert(_ stroke: Stroke, at index: Int) {
        strokes.insert(stroke, at: min(index, strokes.count)); needsDisplay = true
    }

    @discardableResult
    func removeLast() -> Stroke? {
        defer { needsDisplay = true }
        return strokes.popLast()
    }

    func setStrokes(_ new: [Stroke]) { strokes = new; current = nil; needsDisplay = true }

    // MARK: Mouse

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        if controller.tool == .eraser {
            erase(at: point)
            return
        }
        current = Stroke(tool: controller.tool, color: controller.color,
                         width: controller.lineWidth, points: [point])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if controller?.tool == .eraser {
            erase(at: point)
            return
        }
        guard var stroke = current else { return }
        switch stroke.tool {
        case .arrow, .rectangle:
            // Only start and end matter: keep two points.
            stroke.points = [stroke.points[0], point]
        default:
            // Skip samples closer than a point apart; they only add noise.
            if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < 1 { return }
            stroke.points.append(point)
        }
        current = stroke
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard var stroke = current else { return }
        current = nil
        // A plain click with the pen leaves a dot; a click with arrow/rectangle leaves nothing.
        if stroke.tool == .arrow || stroke.tool == .rectangle {
            guard let a = stroke.points.first, let b = stroke.points.last,
                  hypot(b.x - a.x, b.y - a.y) > 3 else { needsDisplay = true; return }
        } else if stroke.points.count == 1 {
            stroke.points.append(stroke.points[0])
        }
        strokes.append(stroke)
        controller?.didAdd(stroke, on: self)
        needsDisplay = true
    }

    /// Removes the topmost mark under the pointer.
    private func erase(at point: CGPoint) {
        guard let index = strokes.lastIndex(where: { $0.hitTest(point, tolerance: 6) }) else { return }
        let removed = strokes.remove(at: index)
        controller?.didErase(removed, at: index, on: self)
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // An almost invisible wash, so the window always counts as "there" for clicks.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.004).cgColor)
        ctx.fill(bounds)

        for stroke in strokes { draw(stroke, in: ctx) }
        if let current { draw(current, in: ctx) }
    }

    private func draw(_ stroke: Stroke, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineCap(stroke.tool == .rectangle ? .square : .round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(stroke.drawWidth)
        ctx.setStrokeColor(stroke.drawColor.cgColor)
        ctx.addPath(stroke.path)
        ctx.strokePath()
        if let head = stroke.arrowHead {
            // Round off the head's corners by stroking it in the same color too.
            ctx.setFillColor(stroke.drawColor.cgColor)
            ctx.addPath(head)
            ctx.drawPath(using: .fillStroke)
        }
        ctx.restoreGState()
    }
}
