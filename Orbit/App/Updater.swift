import AppKit
import Sparkle

/// Automatic updates with Sparkle. The feed address and the public key that checks each update's
/// signature are in Info.plist (SUFeedURL, SUPublicEDKey); scripts/release.sh publishes updates.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    /// Starts checking (once a day by default). Does nothing in previews or outside an .app bundle.
    func start() {
        guard controller == nil, !ModuleRegistry.isPreview,
              Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    // MARK: Orbit has no Dock icon, so bring the update window forward when Sparkle shows it.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
