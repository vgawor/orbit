import SwiftUI

/// A short-lived message that pops the notch open: a meeting starting, an agent asking, a command done.
struct NotchAlert: Identifiable, Equatable {
    struct Action {
        let title: String
        var isPrimary = false
        var tint: Color? = nil
        var perform: (@MainActor () -> Void)? = nil
    }

    let id = UUID()
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let actions: [Action]
    var duration: TimeInterval = 8
    var sound: String? = nil

    static func == (a: NotchAlert, b: NotchAlert) -> Bool { a.id == b.id }
}

/// Modules post alerts here. The notch shows the newest one.
@MainActor
@Observable
final class AlertCenter {
    private(set) var current: NotchAlert?
    private var dismissTask: Task<Void, Never>?

    /// When this returns true (Presenting mode), pop-ups are not shown.
    var isSuppressed: () -> Bool = { false }

    func post(_ alert: NotchAlert) {
        guard !isSuppressed() else { return }
        current = alert
        if let sound = alert.sound { NSSound(named: sound)?.play() }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(alert.duration))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}
