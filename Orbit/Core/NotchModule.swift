import SwiftUI

/// Something that needs you soon: Dot comes out of the closed notch to point at it.
/// `id` should stay the same for the same thing, so it isn't nudged again once you've looked.
struct Attention: Equatable {
    let id: String
    let symbol: String
    let tint: Color
    /// A few words for Dot's bubble, e.g. "3m", "2 overdue", "Claude".
    let label: String
    /// Higher wins when several things need you.
    let priority: Int
    /// A short sentence for the panel's status line, e.g. "Meeting in 4 min". Falls back to `label`.
    var headline: String? = nil
}

/// One short line of info in the peek's chip row, e.g. "Northwind · 32m".
struct PeekChip: Identifiable {
    var id: String { text }
    let symbol: String
    let text: String
    let tint: Color
    /// Higher shows first; only the top few fit.
    let priority: Int
    /// The tab a click opens. Filled in with the module's own id when left empty.
    var target: String? = nil
}

/// Which side of the hardware notch a peek glance sits on.
enum PeekSide { case leading, trailing }

/// A feature that lives in the notch. Every feature (music, tasks, shelf…) is one module.
/// To add a feature: make a type that conforms, then register it in `ModuleRegistry.makeDefault()`.
@MainActor
protocol NotchModule: AnyObject {
    /// Stable id, used for settings and tab selection.
    var id: String { get }
    var title: String { get }
    /// SF Symbol name for the tab bar.
    var symbol: String { get }

    /// Tiny glance shown in the widened pill (Peek). Return nil for none.
    var peekView: AnyView? { get }
    var peekSide: PeekSide { get }
    /// When two modules want the same side, the higher number wins.
    var peekPriority: Int { get }

    /// A one-line chip in the peek. Return nil for none.
    var peekChip: PeekChip? { get }

    /// Card shown on the Home tab. Return nil for none.
    var homeCard: AnyView? { get }
    /// Something important that's about to happen or hasn't been done. Nil when all is well.
    var attention: Attention? { get }
    /// Full view shown when the module's tab is selected.
    var panel: AnyView { get }
    /// False for features that only work in the background (no tab of their own).
    var showsTab: Bool { get }
    /// How many things this feature has running right now (timer, agent session, recording…),
    /// for the "1 running" status in the panel header.
    var runningCount: Int { get }

    func start()
    func stop()
}

extension NotchModule {
    var peekView: AnyView? { nil }
    var peekSide: PeekSide { .trailing }
    var peekPriority: Int { 0 }
    var peekChip: PeekChip? { nil }
    var homeCard: AnyView? { nil }
    var attention: Attention? { nil }
    var showsTab: Bool { true }
    var runningCount: Int { 0 }
    func start() {}
    func stop() {}
}
