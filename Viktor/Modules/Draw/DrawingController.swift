import AppKit
import SwiftUI

/// Screen drawing: draw, highlight and point with arrows on top of everything, on every screen.
///
/// `start()` puts a see-through window over each screen plus a small floating toolbar.
/// `stop()` takes them all away (and the marks with them).
@MainActor
final class DrawingController: ObservableObject {
    // MARK: State the toolbar shows

    @Published private(set) var isActive = false
    @Published var tool: DrawingTool = .pen
    @Published var colorIndex = 0
    @Published var widthIndex = 1
    /// When on, clicks go to the apps below the marks. The toolbar still works.
    @Published var clickThrough = false { didSet { applyClickThrough() } }
    /// True when there is something to undo (drives the Undo button).
    @Published private(set) var canUndo = false

    var color: NSColor { DrawingPalette.colors[colorIndex] }
    var lineWidth: CGFloat { DrawingWidths.all[widthIndex] }

    /// Chip for the notch's peek while drawing is on.
    var peekChip: PeekChip? {
        guard isActive else { return nil }
        return PeekChip(symbol: "pencil.tip", text: "Drawing", tint: Tokens.attention, priority: 6)
    }

    // MARK: Windows

    private var overlays: [DrawingOverlayWindow] = []
    private var canvases: [DrawingCanvasView] = []
    private var toolbar: DrawingToolbarPanel?
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    // MARK: Undo

    /// One step that ⌘Z can take back.
    private enum UndoStep {
        case added(canvas: Int)
        case erased(canvas: Int, stroke: Stroke, index: Int)
        case cleared(snapshot: [[Stroke]])
    }
    private var undoSteps: [UndoStep] = [] { didSet { canUndo = !undoSteps.isEmpty } }

    init() {}

    // MARK: Start / stop

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive else { return }
        isActive = true
        clickThrough = false
        buildOverlays()
        showToolbar()
        installKeyMonitor()

        // If screens are added, removed or rearranged, rebuild the overlays to match.
        // (Marks don't survive this; the old positions wouldn't make sense anyway.)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.tearDownOverlays()
                self.buildOverlays()
                self.placeToolbarAtDefault()
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        tearDownOverlays()
        toolbar?.orderOut(nil)
        toolbar = nil
        undoSteps = []
    }

    // MARK: Actions (toolbar buttons and keys)

    func undo() {
        guard let step = undoSteps.popLast() else { return }
        switch step {
        case .added(let i):
            if canvases.indices.contains(i) { canvases[i].removeLast() }
        case .erased(let i, let stroke, let index):
            if canvases.indices.contains(i) { canvases[i].insert(stroke, at: index) }
        case .cleared(let snapshot):
            for (i, strokes) in snapshot.enumerated() where canvases.indices.contains(i) {
                canvases[i].setStrokes(strokes)
            }
        }
    }

    /// Wipes every screen. Can be undone.
    func clear() {
        let snapshot = canvases.map(\.strokes)
        guard snapshot.contains(where: { !$0.isEmpty }) else { return }
        undoSteps.append(.cleared(snapshot: snapshot))
        canvases.forEach { $0.setStrokes([]) }
    }

    // MARK: Called by the canvases

    func didAdd(_ stroke: Stroke, on canvas: DrawingCanvasView) {
        guard let i = canvases.firstIndex(where: { $0 === canvas }) else { return }
        undoSteps.append(.added(canvas: i))
    }

    func didErase(_ stroke: Stroke, at index: Int, on canvas: DrawingCanvasView) {
        guard let i = canvases.firstIndex(where: { $0 === canvas }) else { return }
        undoSteps.append(.erased(canvas: i, stroke: stroke, index: index))
    }

    // MARK: Overlays

    private func buildOverlays() {
        for screen in NSScreen.screens {
            let window = DrawingOverlayWindow(screen: screen)
            let canvas = DrawingCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
            canvas.autoresizingMask = [.width, .height]
            canvas.controller = self
            window.contentView = canvas
            window.orderFrontRegardless()
            overlays.append(window)
            canvases.append(canvas)
        }
        applyClickThrough()
        focusOverlayUnderMouse()
    }

    private func tearDownOverlays() {
        overlays.forEach { $0.orderOut(nil); $0.close() }
        overlays = []
        canvases = []
        undoSteps = []
    }

    private func applyClickThrough() {
        for window in overlays { window.ignoresMouseEvents = clickThrough }
        if !clickThrough { focusOverlayUnderMouse() }
    }

    /// Makes the overlay on the screen with the pointer the key window, so our keys work.
    private func focusOverlayUnderMouse() {
        guard isActive, !clickThrough else { return }
        let mouse = NSEvent.mouseLocation
        let window = overlays.first { $0.frame.contains(mouse) } ?? overlays.first
        window?.makeKeyAndOrderFront(nil)
        if let canvas = window?.contentView { window?.makeFirstResponder(canvas) }
        toolbar?.orderFrontRegardless()  // keep the toolbar on top
    }

    // MARK: Toolbar

    private func showToolbar() {
        let panel = DrawingToolbarPanel(controller: self)
        toolbar = panel
        placeToolbarAtDefault()
        panel.orderFrontRegardless()
    }

    /// Top-center of the screen with the notch (or the main screen), 60pt below the top edge.
    private func placeToolbarAtDefault() {
        guard let toolbar else { return }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return }
        let size = toolbar.frame.size
        toolbar.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - 60 - size.height))
    }

    // MARK: Keys

    /// Watches keys typed into our overlay or toolbar while drawing is on.
    /// (Click-through hands focus to other apps, so keys are naturally off then.)
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Only a Bool crosses the isolation hop (NSEvent isn't Sendable).
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isOurs(event.window) else { return false }
                return self.handleKey(event)
            }
            return used ? nil : event
        }
    }

    private func isOurs(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === toolbar || overlays.contains { $0 === window }
    }

    /// Returns true if the key was used.
    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 { stop(); return true }                       // Esc → Done
        if mods == .command && key == "z" { undo(); return true }            // ⌘Z
        if mods == .command && key == "k" { clear(); return true }           // ⌘K → Clear
        guard mods.subtracting([.shift, .capsLock]).isEmpty else { return false }

        switch key {
        case "p": tool = .pen
        case "h": tool = .highlighter
        case "a": tool = .arrow
        case "r": tool = .rectangle
        case "e": tool = .eraser
        case "t": clickThrough.toggle()
        case "1", "2", "3", "4", "5", "6":
            colorIndex = Int(key)! - 1
            if tool == .eraser { tool = .pen }
        default: return false
        }
        return true
    }
}
