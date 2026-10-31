import AppKit
import SwiftUI

/// Borderless panel that floats over the menu bar, on every Space, including full-screen apps.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 1
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
    }

    // Needed so text fields (tasks, notes) can take typing.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Places the panel at the notch, and turns mouse movement into closed → peek → open → closed.
@MainActor
final class NotchWindowController {
    private let panel = NotchPanel()
    private let vm: NotchViewModel
    private let alerts: AlertCenter
    private var monitors: [Any] = []
    private var pendingTask: Task<Void, Never>?
    private var screen: NSScreen?

    /// Extra room around the largest shape so its shadow isn't clipped.
    private let shadowMargin: CGFloat = 40

    private let registry: ModuleRegistry

    init(vm: NotchViewModel, registry: ModuleRegistry, alerts: AlertCenter) {
        self.vm = vm
        self.registry = registry
        self.alerts = alerts
        let root = NotchRootView(vm: vm, registry: registry, alerts: alerts)
        let host = ClickThroughHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        position()
        panel.orderFrontRegardless()
        installMonitors()
        observeState()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
    }

    // MARK: Placement

    /// Prefer the built-in display with a notch; otherwise the main display.
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func position() {
        guard let screen = targetScreen() else { return }
        self.screen = screen
        vm.screenFrame = screen.frame

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            vm.notchSize = CGSize(width: width, height: screen.safeAreaInsets.top)
            vm.hasHardwareNotch = true
        } else {
            // No notch: a slim pill tucked into the menu bar.
            // No notch: a glass pill floating just below the menu bar.
            vm.notchSize = CGSize(width: 190, height: 30)
            vm.hasHardwareNotch = false
        }
        vm.menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)

        let w = vm.maxSize.width + shadowMargin * 2
        let h = vm.maxSize.height + shadowMargin + vm.floatGap
        let frame = NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
        panel.setFrame(frame, display: true)
    }

    // MARK: Mouse

    /// Screen rect of the black shape for a given state (bottom-left origin, like NSEvent).
    private func shapeRect(for state: NotchState, padding: CGFloat = 0) -> NSRect {
        guard let screen else { return .zero }
        let size = vm.size(for: state)
        return NSRect(x: screen.frame.midX - size.width / 2 - padding,
                      y: screen.frame.maxY - vm.floatGap - size.height - padding,
                      width: size.width + padding * 2,
                      height: size.height + padding + 1)
    }

    /// Generous areas around the notch, so it's easy to reach: wider than the shape, and
    /// reaching a bit below it. Pushing the pointer against the top edge of the screen counts too.
    private func hoverZone(for state: NotchState) -> NSRect {
        switch state {
        case .closed:
            var r = shapeRect(for: .closed, padding: 0)
            r = r.insetBy(dx: -40, dy: 0)
            // Reaches up to the top edge, so pushing the pointer up still works when the pill floats.
            r.origin.y -= 10; r.size.height += 10 + vm.floatGap
            return r
        case .peek:
            var r = shapeRect(for: .peek, padding: 0)
            r = r.insetBy(dx: -16, dy: 0)
            r.origin.y -= 14; r.size.height += 14
            return r
        default:
            return shapeRect(for: state, padding: 8)
        }
    }

    /// While Dot is nudging under the closed notch, hovering Dot or its bubble opens the peek too.
    private var nudgeRect: NSRect {
        guard vm.nudge != nil, let screen else { return .zero }
        let width: CGFloat = 240, height = vm.floatGap + vm.notchSize.height + 50
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }) { monitors.append(m) }
        // A click anywhere outside closes the panel. Also remember the drag pasteboard,
        // so a new file drag can be told apart from an old one.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dragBaseline = NSPasteboard(name: .drag).changeCount
                // A click on the notch area always opens it, even if the click went to the app below.
                if self.vm.state == .closed || self.vm.state == .peek,
                   self.hoverZone(for: self.vm.state).contains(NSEvent.mouseLocation) {
                    self.cancelPending()
                    self.vm.state = .open
                    return
                }
                guard self.vm.state == .open else { return }
                if !self.shapeRect(for: .open).contains(NSEvent.mouseLocation) { self.vm.close() }
            }
        }) { monitors.append(m) }
        // Right-clicking Orbit (while it nudges) or the peeking notch offers to snooze what it's about.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.rightClicked() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown], handler: { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            return MainActor.assumeIsolated { self.rightClicked() } ? nil : e
        }) { monitors.append(m) }
        // Releasing a file anywhere but on the drop zones closes them.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.vm.state == .drop else { return }
                self.schedule(after: 0.4) { vm in if vm.state == .drop { vm.close() } }
            }
        }) { monitors.append(m) }
        // Esc closes.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            // Only Esc pressed in the notch itself closes it (other windows, like drawing, handle their own Esc).
            if e.keyCode == 53, let self, e.window === self.panel {
                MainActor.assumeIsolated { self.vm.close() }
                return nil
            }
            return e
        }) { monitors.append(m) }
    }

    /// Shows the snooze menu if the right-click was on Orbit or the closed/peeking notch.
    private func rightClicked() -> Bool {
        guard vm.state == .closed || vm.state == .peek else { return false }
        let p = NSEvent.mouseLocation
        guard hoverZone(for: vm.state).contains(p) || nudgeRect.contains(p) else { return false }
        let target = vm.nudge ?? registry.topAttention
        guard target != nil || NudgeSnoozes.shared.hasActive() else { return false }
        cancelPending()
        SnoozeMenu.popUp(for: target) { [weak self] in
            guard let self else { return }
            self.vm.updateNudge(self.registry.topAttention)
            if self.vm.state == .peek { self.vm.close() }
        }
        return true
    }

    private var dragBaseline = NSPasteboard(name: .drag).changeCount

    /// True while the user is dragging files (not text or other content).
    /// What's being dragged right now: files, a web link (e.g. YouTube from the browser), or nothing we handle.
    private var draggedKind: NotchViewModel.DragKind? {
        guard NSEvent.pressedMouseButtons & 1 == 1 else { return nil }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragBaseline, let types = pb.types else { return nil }
        if types.contains(.fileURL) { return .files }
        if types.contains(.URL) || types.contains(NSPasteboard.PasteboardType("public.url")) { return .link }
        if let s = pb.string(forType: .string), s.hasPrefix("http") { return .link }
        return nil
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        let insideCurrent = shapeRect(for: vm.state).contains(p)
        panel.ignoresMouseEvents = !(insideCurrent && vm.state != .closed)

        // A file dragged near the notch opens the drop zones.
        if let kind = draggedKind, vm.state == .closed || vm.state == .peek {
            vm.dragKind = kind
            if shapeRect(for: .peek, padding: 40).contains(p) {
                cancelPending()
                vm.state = .drop
                panel.ignoresMouseEvents = false
            }
            return
        }

        switch vm.state {
        case .closed:
            if hoverZone(for: .closed).contains(p) || nudgeRect.contains(p) {
                schedule(after: 0.15) { vm in vm.state = .peek }
            } else {
                cancelPending()
            }
        case .peek:
            // Peek stays while you hover; a click opens the full panel. After the pointer
            // leaves it lingers for a few seconds (Settings), then slides away.
            // `keep: true` so moving the pointer around elsewhere doesn't restart the countdown.
            if hoverZone(for: .peek).contains(p) {
                cancelPending()
            } else {
                schedule(after: max(vm.peekLinger, 0.2), keep: true) { vm in if vm.state == .peek { vm.close() } }
            }
        case .open:
            // Opened with ⌥Space, or set to stay until a click outside: only Esc, a click outside or ⌥Space close it.
            if vm.openedByKeyboard || vm.openLinger < 0 { return }
            if shapeRect(for: .open, padding: 12).contains(p) {
                cancelPending()
            } else {
                // Lingers for the chosen time (Settings), then closes; moving elsewhere doesn't restart the countdown.
                schedule(after: max(vm.openLinger, 0.3), keep: true) { vm in if vm.state == .open { vm.close() } }
            }
        case .alert:
            break
        case .drop:
            if shapeRect(for: .drop, padding: 60).contains(p) {
                cancelPending()
            } else {
                schedule(after: 0.3) { vm in if vm.state == .drop { vm.close() } }
            }
        }
    }

    /// Runs `change` after a delay unless the mouse moves somewhere that cancels it.
    /// `keep: true` leaves an already-scheduled change of the same kind running.
    private var pendingIsKeep = false
    private func schedule(after seconds: Double, keep: Bool = false, _ change: @escaping @MainActor (NotchViewModel) -> Void) {
        if keep && pendingTask != nil && pendingIsKeep { return }
        pendingTask?.cancel()
        pendingIsKeep = keep
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            change(self.vm)
            self.pendingTask = nil
            self.mouseMoved()
        }
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    // MARK: State

    /// Alerts pop the notch open; when the alert goes away, the notch closes again.
    private func observeState() {
        withObservationTracking {
            _ = alerts.current
            _ = vm.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.alerts.current != nil, self.vm.state != .open {
                    self.vm.state = .alert
                } else if self.alerts.current == nil, self.vm.state == .alert {
                    self.vm.close()
                }
                if self.vm.state == .open { self.panel.makeKey() }
                self.panel.ignoresMouseEvents = self.vm.state == .closed
                self.observeState()
            }
        }
    }
}

/// Takes the first click even though the panel isn't the active window, so one click is enough.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
