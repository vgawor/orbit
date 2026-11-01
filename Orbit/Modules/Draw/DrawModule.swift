import Combine
import SwiftUI

/// Screen drawing as a module: shows a "Drawing" chip while active. Started from Capture → Draw,
/// the menu bar, or ⌃⌥D. Has no tab of its own.
@MainActor
@Observable
final class DrawModule: NotchModule {
    let id = "draw"
    let title = "Draw"
    let symbol = "pencil.tip"
    var showsTab: Bool { false }

    let controller = DrawingController()
    private(set) var active = false
    @ObservationIgnored private var sub: AnyCancellable?

    init() {
        sub = controller.$isActive.sink { [weak self] on in
            MainActor.assumeIsolated { self?.active = on }
        }
    }

    func toggle() { controller.toggle() }
    func start() {}
    func stop() { controller.stop() }

    var peekChip: PeekChip? { active ? controller.peekChip : nil }

    var panel: AnyView { AnyView(EmptyView()) }
}
