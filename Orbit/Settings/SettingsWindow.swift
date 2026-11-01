import AppKit

/// Keeps the Settings window usable from the notch.
///
/// Orbit has no Dock icon, so macOS treats its windows as background windows: Settings opened
/// under the notch panel and fell behind other apps as soon as the notch closed. While Settings
/// is open, Orbit becomes a normal app (Dock icon, ⌘Tab) and the window sits below the notch area.
@MainActor
enum SettingsWindow {
    /// Set by the app: closes the notch panel.
    static var closeNotch: (() -> Void)?
    /// Set by the app: how far down the open notch panel reaches, so Settings opens below it.
    static var notchHeight: () -> CGFloat = { 0 }

    private static var placed = false
    private static var closeObserver: NSObjectProtocol?

    /// Call when a Settings link inside the notch is tapped.
    static func willOpen() {
        closeNotch?()
        // SwiftUI creates the window a moment after the tap.
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { bringForward() }
        }
    }

    /// Makes Orbit a normal app while Settings is open and puts the window in front.
    static func bringForward() {
        guard let window else { return }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        window.hidesOnDeactivate = false
        if !placed { place(window); placed = true }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
                    closeObserver = nil
                    placed = false
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    private static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }
    }

    /// Centred horizontally, with its top below the open notch panel when there's room.
    private static func place(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        var frame = window.frame
        frame.origin.x = area.midX - frame.width / 2
        let belowNotch = screen.frame.maxY - notchHeight() - 16
        let top = min(area.maxY, belowNotch)
        frame.origin.y = max(area.minY, top - frame.height)
        window.setFrame(frame, display: false)
    }
}
