import AppKit
import SwiftUI

/// The snooze choices as SwiftUI buttons, for menus and context menus.
struct SnoozeMenuItems: View {
    let attention: Attention
    var snoozes = NudgeSnoozes.shared

    var body: some View {
        Section("Snooze “\(attention.headline ?? attention.label)”") {
            ForEach(SnoozeOption.allCases) { option in
                Button(option.title) { snoozes.snooze(attention.id, option) }
            }
        }
        if snoozes.hasActive() {
            Button("Show snoozed reminders again") { snoozes.wakeAll() }
        }
    }
}

/// A small "Snooze" button with the three choices. Shows "Snoozed" (and Wake) once snoozed.
struct SnoozeMenuButton: View {
    let attentionID: String
    var snoozes = NudgeSnoozes.shared

    var body: some View {
        let snoozed = snoozes.isSnoozed(attentionID)
        Menu {
            if snoozed {
                Button("Remind me again") { snoozes.wake(attentionID) }
            } else {
                ForEach(SnoozeOption.allCases) { option in
                    Button(option.title) { snoozes.snooze(attentionID, option) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: snoozed ? "bell.slash.fill" : "zzz").font(.system(size: 9, weight: .semibold))
                Text(snoozed ? "Snoozed" : "Snooze").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(snoozed ? Tokens.secondary : .white.opacity(0.85))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(Tokens.surface2))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(snoozed ? "Orbit won't nudge you about these until the snooze ends" : "Stop Orbit nudging you about overdue tasks for a while")
    }
}

/// The same menu in AppKit, for right-clicking Orbit or the notch when SwiftUI can't take the click.
@MainActor
enum SnoozeMenu {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    /// Shows the menu at the pointer. `after` runs once a choice is made.
    static func popUp(for attention: Attention?, snoozes: NudgeSnoozes = .shared, after: @escaping () -> Void = {}) {
        let menu = NSMenu()
        var targets: [Target] = []
        func add(_ title: String, _ action: @escaping () -> Void) {
            let target = Target { action(); after() }
            targets.append(target)
            let item = NSMenuItem(title: title, action: #selector(Target.run), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        if let attention {
            let header = NSMenuItem(title: "Snooze “\(attention.headline ?? attention.label)”", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for option in SnoozeOption.allCases {
                add(option.title) { snoozes.snooze(attention.id, option) }
            }
        }
        if snoozes.hasActive() {
            if attention != nil { menu.addItem(.separator()) }
            add("Show snoozed reminders again") { snoozes.wakeAll() }
        }
        guard !menu.items.isEmpty else { return }
        _ = withExtendedLifetime(targets) {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}
