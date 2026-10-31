import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Where captures go and how they're named: the same folder macOS saves screenshots to.
enum CaptureFiles {
    /// `defaults read com.apple.screencapture location`, or ~/Desktop.
    static var folder: URL {
        let fm = FileManager.default
        if let raw = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !raw.isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return fm.homeDirectoryForCurrentUser.appending(path: "Desktop", directoryHint: .isDirectory)
    }

    /// e.g. "Orbit 2026-10-27 at 14.03.12.png". Adds " 2", " 3"… if the name is taken.
    static func newURL(_ prefix: String = "Orbit", ext: String) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "\(prefix) \(f.string(from: .now))"
        let dir = folder
        var url = dir.appending(path: "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appending(path: "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// True when Orbit may read the screen. (Turning it on needs a relaunch of Orbit.)
    static var hasScreenPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// System Settings → Privacy & Security → Screen Recording.
    @MainActor static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// ScreenCaptureKit's "user declined" error (-3801) means no Screen Recording permission.
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue
    }

    /// Runs /usr/sbin/screencapture off the main thread and returns its exit status.
    static func screencapture(_ args: [String]) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = args
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
    }
}

/// Lets a CGImage / SCContentFilter cross into another isolation domain. They are never mutated after creation.
struct ImageBox: @unchecked Sendable { let image: CGImage }
struct FilterBox: @unchecked Sendable { let filter: SCContentFilter }
