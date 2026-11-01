import AppKit
import ScreenCaptureKit
import SwiftUI

/// Scrolling screenshot: drag a region, scroll, press Finish. The region stays outlined while you
/// scroll; frames are grabbed with ScreenCaptureKit about 4× a second and stitched into one PNG.
@MainActor
final class ScrollingCapture {
    enum Outcome { case saved(URL), cancelled, failed(String), noPermission }

    @Observable @MainActor
    final class State {
        var heightPoints = 0
        var isFull = false
        var saving = false
    }

    private let onDone: @MainActor (Outcome) -> Void
    private let state = State()
    private var selectionWindows: [NSWindow] = []
    private var outlineWindow: NSWindow?
    private var controlPanel: NSPanel?
    private var loop: Task<Void, Never>?
    private var stitcher = ScrollStitcher()
    private var grabber: FrameGrabber?
    private var scale: CGFloat = 2
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var finished = false

    init(onDone: @escaping @MainActor (Outcome) -> Void) { self.onDone = onDone }

    // MARK: 1. Select a region

    func begin() {
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onSelect = { [weak self] rect in self?.selected(rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), on: screen) }
            view.onCancel = { [weak self] in self?.finish(.cancelled) }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            selectionWindows.append(window)
        }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        let key = selectionWindows.first { $0.frame.contains(mouse) } ?? selectionWindows.first
        key?.makeKeyAndOrderFront(nil)
        key?.makeFirstResponder(key?.contentView)
    }

    private func selected(_ rect: CGRect, on screen: NSScreen) {
        selectionWindows.forEach { $0.orderOut(nil) }
        selectionWindows.removeAll()
        let rect = rect.integral
        guard rect.width >= 24, rect.height >= 24 else { finish(.cancelled); return }
        previousApp?.activate()
        showOutline(rect)
        showControls(near: rect, on: screen)
        startCapturing(rect, on: screen)
    }

    // MARK: 2. Outline + controls

    private func showOutline(_ rect: CGRect) {
        let frame = rect.insetBy(dx: -4, dy: -4)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = OutlineView(frame: CGRect(origin: .zero, size: frame.size))
        window.orderFrontRegardless()
        outlineWindow = window
    }

    private func showControls(near rect: CGRect, on screen: NSScreen) {
        let size = CGSize(width: 300, height: 44)
        let visible = screen.visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - 12 - size.height)
        if origin.y < visible.minY { origin.y = rect.maxY + 12 }
        if origin.y + size.height > visible.maxY { origin.y = rect.minY + 12 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)

        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScrollingControls(
            state: state, scale: screen.backingScaleFactor,
            finish: { [weak self] in self?.save() },
            cancel: { [weak self] in self?.finish(.cancelled) }))
        panel.orderFrontRegardless()
        controlPanel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(.cancelled); return nil }
            if event.keyCode == 36 { self?.save(); return nil }
            return event
        }
    }

    // MARK: 3. Capture loop

    private func startCapturing(_ rect: CGRect, on screen: NSScreen) {
        guard CaptureFiles.hasScreenPermission else { finish(.noPermission); return }
        scale = screen.backingScaleFactor
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        // Region in the display's own points, top-left origin.
        let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
        let scale = self.scale
        FrameGrabber.make(displayID: displayID, region: local, scale: scale) { [weak self] result in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                switch result {
                case .success(let grabber):
                    self.grabber = grabber
                    self.runLoop(grabber)
                case .failure(let error):
                    self.finish(CaptureFiles.isPermissionError(error) ? .noPermission : .failed(error.localizedDescription))
                }
            }
        }
    }

    private func runLoop(_ grabber: FrameGrabber) {
        let stitcher = self.stitcher
        let state = self.state
        let scale = self.scale
        loop = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    let box = try await grabber.grab()
                    failures = 0
                    let px = await stitcher.add(box)
                    state.heightPoints = Int(CGFloat(px) / scale)
                    state.isFull = await stitcher.isFull
                } catch {
                    failures += 1
                    if CaptureFiles.isPermissionError(error) { self?.finish(.noPermission); return }
                    if failures >= 8 { self?.finish(.failed(error.localizedDescription)); return }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // MARK: 4. Finish

    private func save() {
        guard !finished, !state.saving else { return }
        state.saving = true
        loop?.cancel()
        let stitcher = self.stitcher
        let grabber = self.grabber
        let scale = self.scale
        Task { [weak self] in
            // One last frame so the final scroll position is included.
            if let grabber, let box = try? await grabber.grab() { await stitcher.add(box) }
            let url = CaptureFiles.newURL(ext: "png")
            let ok = await stitcher.writePNG(to: url, scale: scale)
            self?.finish(ok ? .saved(url) : .failed("Nothing was captured"))
        }
    }

    func cancel() { finish(.cancelled) }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        loop?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        selectionWindows.forEach { $0.orderOut(nil) }
        selectionWindows.removeAll()
        outlineWindow?.orderOut(nil); outlineWindow = nil
        controlPanel?.orderOut(nil); controlPanel = nil
        onDone(outcome)
    }
}

// MARK: - ScreenCaptureKit

/// Grabs one region of one display, excluding Orbit's own windows.
final class FrameGrabber: @unchecked Sendable {
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration

    private init(filter: SCContentFilter, config: SCStreamConfiguration) {
        self.filter = filter
        self.config = config
    }

    static func make(displayID: CGDirectDisplayID, region: CGRect, scale: CGFloat,
                     completion: @escaping @Sendable (Result<FrameGrabber, Error>) -> Void) {
        let pid = ProcessInfo.processInfo.processIdentifier
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content else {
                completion(.failure(error ?? NSError(domain: "Orbit.Capture", code: 1,
                                                     userInfo: [NSLocalizedDescriptionKey: "Couldn't read the screen"])))
                return
            }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                completion(.failure(NSError(domain: "Orbit.Capture", code: 2,
                                            userInfo: [NSLocalizedDescriptionKey: "No display found"])))
                return
            }
            let mine = content.applications.filter { $0.processID == pid }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = region
            config.width = Int((region.width * scale).rounded())
            config.height = Int((region.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            completion(.success(FrameGrabber(filter: filter, config: config)))
        }
    }

    func grab() async throws -> ImageBox {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ImageBox, Error>) in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let image { cont.resume(returning: ImageBox(image: image)) }
                else { cont.resume(throwing: error ?? NSError(domain: "Orbit.Capture", code: 3)) }
            }
        }
    }
}

// MARK: - Windows and views

/// Borderless windows can't become key by default; the selection overlay needs Esc.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Dims the screen; drag with a crosshair to cut out a region. Esc cancels.
private final class SelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let sel = selection {
            NSColor.clear.setFill()
            sel.fill(using: .copy)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            path.lineWidth = 1
            path.stroke()
            let label = "\(Int(sel.width)) × \(Int(sel.height))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                        .foregroundColor: NSColor.white]
            label.draw(at: CGPoint(x: sel.minX, y: max(4, sel.minY - 18)), withAttributes: attrs)
        } else {
            let hint = "Drag to select the area to scroll · Esc to cancel" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                        .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if let sel = selection { onSelect?(sel) } else { onCancel?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A dashed outline around the region being captured.
private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2.5, dy: 2.5)
        let back = NSBezierPath(rect: r)
        back.lineWidth = 2
        NSColor.black.withAlphaComponent(0.6).setStroke()
        back.stroke()
        let dash = NSBezierPath(rect: r)
        dash.lineWidth = 2
        dash.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.white.setStroke()
        dash.stroke()
    }
}

/// The small floating bar: captured height, Cancel, Finish.
private struct ScrollingControls: View {
    let state: ScrollingCapture.State
    let scale: CGFloat
    let finish: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.live)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.saving ? "Saving…" : state.isFull ? "Maximum length reached" : "Scroll down, then Finish")
                    .font(.system(size: 11.5, weight: .medium))
                Text("\(state.heightPoints) pt captured")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Tokens.secondary)
            }
            Spacer(minLength: 4)
            PillButton(title: "Cancel", fill: Tokens.surface2, action: cancel)
            PillButton(title: "Finish", action: finish)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black, in: Capsule())
        .overlay(Capsule().stroke(Tokens.stroke))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .disabled(state.saving)
    }
}
