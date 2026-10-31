import SwiftUI

enum NotchState: Equatable {
    case closed, peek, open, alert, drop
}

/// Shared state for the notch: which state it's in, which tab is selected and how big things are.
@MainActor
@Observable
final class NotchViewModel {
    var state: NotchState = .closed {
        didSet {
            // Peeking or opening counts as having seen what Dot was pointing at.
            // (An alert popping up on its own doesn't, so Dot keeps nudging after it goes away.)
            if state == .peek || state == .open, let n = nudge {
                nudgeSeen[n.id] = .now
                nudge = nil
            }
        }
    }

    /// What Dot is currently pointing at from the closed notch, if anything.
    private(set) var nudge: Attention?
    private var nudgeSeen: [String: Date] = [:]
    /// After you've looked, the same thing nudges again only after this long.
    static let renudgeAfter: TimeInterval = 15 * 60

    enum DragKind { case files, link }
    /// What's being dragged onto the notch, so the drop zones can match it.
    var dragKind: DragKind = .files

    /// Presenting mode: notch content and pop-ups are hidden, so nothing private shows while you share your screen.
    var presenting = false {
        didSet { if presenting { nudge = nil } }
    }

    func updateNudge(_ top: Attention?) {
        guard let top, !presenting, !NudgeSnoozes.shared.isSnoozed(top.id) else { nudge = nil; return }
        guard state == .closed || state == .alert else { return }
        if let seen = nudgeSeen[top.id], Date.now.timeIntervalSince(seen) < Self.renudgeAfter {
            nudge = nil
        } else {
            nudge = top
        }
    }
    var selectedTab = "home" {
        didSet { Onboarding.visited(selectedTab) }
    }

    /// Size of the hardware notch (or the fallback pill on displays without one).
    var notchSize = CGSize(width: 190, height: 32)
    var hasHardwareNotch = true

    /// Show the closed pill on displays without a notch (off by default: it's invisible until hovered).
    var showPillWithoutNotch = UserDefaults.standard.bool(forKey: "showPillWithoutNotch") {
        didSet { UserDefaults.standard.set(showPillWithoutNotch, forKey: "showPillWithoutNotch") }
    }

    /// Dot comes out of the notch when something needs you (meetings, Claude, overdue tasks).
    var companionFlight = UserDefaults.standard.object(forKey: "companionFlight") as? Bool ?? true {
        didSet { UserDefaults.standard.set(companionFlight, forKey: "companionFlight") }
    }

    /// The screen the notch is on (for the peek dot's eyes to follow the pointer).
    var screenFrame: CGRect = .zero

    /// Seconds the peek stays after the pointer leaves it.
    var peekLinger: Double = UserDefaults.standard.object(forKey: "peekLinger") as? Double ?? 4 {
        didSet { UserDefaults.standard.set(peekLinger, forKey: "peekLinger") }
    }

    /// Seconds the open notch stays after the pointer leaves it. -1 = until you click outside (or press Esc).
    var openLinger: Double = UserDefaults.standard.object(forKey: "openLinger") as? Double ?? 0.3 {
        didSet { UserDefaults.standard.set(openLinger, forKey: "openLinger") }
    }

    /// Extra height while the peek dot tugs the pill.
    var tug: CGFloat = 0

    /// Opened with the keyboard shortcut: stays open until Esc, the shortcut, or a click outside.
    var openedByKeyboard = false

    /// Height of the menu bar on the current screen.
    var menuBarHeight: CGFloat = 24
    /// Without a hardware notch, Orbit floats as a glass pill just below the menu bar instead of
    /// hanging from the top edge. This is how far down it starts.
    var floatGap: CGFloat { hasHardwareNotch ? 0 : menuBarHeight + 6 }

    let openSize = CGSize(width: 700, height: 560)
    let alertSize = CGSize(width: 520, height: 112)
    let dropSize = CGSize(width: 560, height: 150)
    /// How far the peek reaches out on each side of the notch, and how far it drops below it.
    let peekExtra: CGFloat = 130
    let peekDrop: CGFloat = 12
    /// Height of the row of info chips under the peek.
    let peekChips: CGFloat = 30

    /// Largest size the shape can reach. The window is sized to fit this plus room for the shadow.
    var maxSize: CGSize { openSize }

    var currentSize: CGSize { size(for: state) }

    func size(for state: NotchState) -> CGSize {
        switch state {
        case .closed: notchSize
        case .peek: CGSize(width: notchSize.width + peekExtra * 2, height: notchSize.height + peekDrop + peekChips + tug)
        case .open: openSize
        case .alert: alertSize
        case .drop: dropSize
        }
    }

    var bottomRadius: CGFloat {
        switch state {
        case .closed: hasHardwareNotch ? 10 : notchSize.height / 2
        case .peek: 18
        case .open: 36
        case .alert: 26
        case .drop: 28
        }
    }

    func toggleFromKeyboard() {
        if state == .open {
            close()
        } else {
            openedByKeyboard = true
            Onboarding.visited("shortcut")
            state = .open
        }
    }

    func close() {
        openedByKeyboard = false
        state = .closed
    }
}
