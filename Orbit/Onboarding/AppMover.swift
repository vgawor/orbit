import AppKit

/// Offers to move Orbit into Applications when it's opened from the DMG or from Downloads.
/// Running from there breaks Start at login and automatic updates, and the DMG copy disappears
/// when the disk is ejected.
@MainActor
enum AppMover {
    static let dontAskKey = "appMover.dontAsk"

    /// Where the app runs from, if it isn't in an Applications folder.
    static var needsMove: Bool {
        let path = Bundle.main.bundlePath
        guard Bundle.main.bundleURL.pathExtension == "app", !ModuleRegistry.isPreview else { return false }
        if path.hasPrefix("/Applications/") { return false }
        if path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/") { return false }
        // Development copies (scripts/build-app.sh output, swift run) stay where they are.
        if path.contains("/build/") || path.contains("/.build/") { return false }
        return true
    }

    /// Asks, and moves + relaunches if you say yes. Returns true when the app is about to quit.
    static func offerIfNeeded() -> Bool {
        guard needsMove, !UserDefaults.standard.bool(forKey: dontAskKey) else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Orbit to Applications?"
        alert.informativeText = "Orbit is running from \(Bundle.main.bundlePath.contains("/Volumes/") || Bundle.main.bundlePath.contains("AppTranslocation") ? "the disk image" : "your Downloads folder"). In Applications it can start when you log in and update itself."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: dontAskKey) }
        guard answer == .alertFirstButtonReturn else { return false }
        do {
            let dest = try move()
            relaunch(at: dest)
            return true
        } catch {
            let fail = NSAlert()
            fail.messageText = "Couldn't move Orbit"
            fail.informativeText = "\(error.localizedDescription)\n\nDrag Orbit from the disk image to the Applications folder yourself, then open it from there."
            fail.runModal()
            return false
        }
    }

    /// Copies (from a disk image) or moves (from anywhere else) the app into /Applications.
    private static func move() throws -> URL {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let dest = URL(fileURLWithPath: "/Applications").appendingPathComponent("Orbit.app")
        if fm.fileExists(atPath: dest.path) {
            try fm.trashItem(at: dest, resultingItemURL: nil)
        }
        let fromDiskImage = source.path.hasPrefix("/Volumes/") || source.path.contains("/AppTranslocation/")
        if fromDiskImage {
            try fm.copyItem(at: source, to: dest)
        } else {
            try fm.moveItem(at: source, to: dest)
        }
        // You already chose to open Orbit; don't make macOS ask again for the copy.
        removeQuarantine(dest)
        return dest
    }

    private static func removeQuarantine(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? p.run()
        p.waitUntilExit()
    }

    private static func relaunch(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
