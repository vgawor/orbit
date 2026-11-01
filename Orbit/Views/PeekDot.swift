import AppKit
import SwiftUI

/// Orbit coming out of the closed notch when something needs you.
///
/// When something needs you and the notch is closed (a meeting about to start, Claude waiting,
/// overdue tasks), Orbit comes out on its own with a little bubble saying what it is, bounces,
/// wiggles and tugs at the notch until you open it.
struct PeekDot: View {
    let vm: NotchViewModel

    enum Mode: Equatable { case off, peek, nudge }

    enum Mood { case normal, wide, squint, grumpy, happy, closed }

    @State private var visible = false
    @State private var x: CGFloat = 0
    @State private var hop: CGFloat = 0
    @State private var drop: CGFloat = 0        // pulled down below its resting spot while tugging
    @State private var neck: CGFloat = 0        // 0…1, the gooey bit of notch it's pulling on
    @State private var squash = CGSize(width: 1, height: 1)
    @State private var lean: Double = 0
    @State private var spin: Double = 0
    @State private var jitter: CGFloat = 0
    @State private var mood: Mood = .normal
    @State private var look: CGVector?          // nil: follow the pointer

    private let size: CGFloat = 28
    private let gap: CGFloat = 8

    /// Orbit only comes out for notifications (nudges), never during a normal peek.
    private var mode: Mode {
        vm.state == .closed && vm.nudge != nil ? .nudge : .off
    }
    /// Restarts Orbit's routine whenever the mode or the thing it points at changes.
    private var routineKey: String { "\(mode)-\(vm.nudge?.id ?? "")" }

    /// Where Orbit hangs from while nudging: the hardware notch, or the top edge of the screen
    /// when there's no notch (only Orbit shows, no pill).
    private var nudgeTop: CGFloat {
        if vm.hasHardwareNotch { return vm.notchSize.height }
        // No notch: under the floating pill if it's shown, otherwise right under the menu bar.
        return vm.showPillWithoutNotch ? vm.floatGap + vm.notchSize.height : vm.menuBarHeight
    }

    private var pillBottom: CGFloat {
        mode == .nudge ? nudgeTop + vm.tug : vm.floatGap + vm.size(for: .peek).height
    }
    /// How far left/right it may go: the width of the pill, minus room for the rounded corners.
    private var range: CGFloat { max(vm.size(for: .peek).width / 2 - 36, 40) }

    var body: some View {
        let dotTop = pillBottom + gap + drop - hop
        ZStack(alignment: .top) {
            GooNeck()
                .fill(.black)
                .frame(width: 30, height: max(gap + drop + size / 2 + 1, 1))
                .scaleEffect(x: 0.6 + 0.4 * neck, y: neck, anchor: .top)
                .opacity(neck > 0.02 ? 1 : 0)
                .offset(x: x + jitter, y: pillBottom - 1)

            face
                .frame(width: size, height: size)
                .scaleEffect(x: squash.width, y: squash.height, anchor: .bottom)
                .rotationEffect(.degrees(lean + spin))
                .scaleEffect(visible ? 1 : 0.1, anchor: .top)
                .opacity(visible ? 1 : 0)
                .offset(x: x + jitter, y: dotTop)

            // The bubble beside Orbit saying what needs you. Follows Orbit without squashing.
            Color.clear
                .frame(width: size, height: size)
                .overlay(alignment: .leading) {
                    if let a = vm.nudge, mode == .nudge {
                        NudgeBubble(attention: a).fixedSize().offset(x: size + 7)
                    }
                }
                .opacity(mode == .nudge && visible ? 1 : 0)
                .scaleEffect(mode == .nudge && visible ? 1 : 0.6, anchor: .leading)
                .offset(x: x + jitter, y: dotTop)
        }
        .allowsHitTesting(false)
        .task(id: routineKey) {
            switch mode {
            case .off: return
            case .peek:
                return
            case .nudge:
                await nudge()
            }
        }
        .onChange(of: routineKey) { _, _ in
            visible = false; x = 0; hop = 0; drop = 0; neck = 0; jitter = 0
            squash = CGSize(width: 1, height: 1); lean = 0; spin = 0
            mood = .normal; look = nil
            vm.tug = 0
        }
    }

    // MARK: Face

    private var face: some View {
        // Orbit follows the pointer with its eyes; its ring glows in the colour of what needs you.
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
            OrbitView(size: size, mood: OrbitView.Mood(rawValue: "\(mood)") ?? .normal,
                      motion: mood == .squint ? .working : .glow,
                      tint: vm.nudge?.tint ?? Tokens.attention,
                      gaze: look ?? pointerGaze())
        }
    }

    /// Direction from Orbit to the mouse pointer, as a vector up to length 1.
    private func pointerGaze() -> CGVector {
        let screen = vm.screenFrame
        guard screen.width > 0 else { return .zero }
        let mouse = NSEvent.mouseLocation
        let cx = screen.midX + x
        let cy = screen.maxY - (pillBottom + gap + drop - hop + size / 2)
        let dx = mouse.x - cx, dy = cy - mouse.y // SwiftUI's y grows downward
        let len = max(hypot(dx, dy), 0.001)
        let strength = min(len / 80, 1)
        return CGVector(dx: dx / len * strength, dy: dy / len * strength)
    }

    // MARK: Life

    private func wait(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled && mode != .off
    }

    /// Grabs the notch where Orbit is and pulls, straining and shaking. The notch snaps it back each time.
    private func pull(times: Int, strength: CGFloat = 1) async -> Bool {
        withAnimation(.easeOut(duration: 0.15)) { neck = 1 }
        guard await wait(0.15) else { return false }
        mood = .squint

        for pull in 0..<times {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                drop = (.random(in: 9...15) + CGFloat(pull) * 2) * strength
                squash = CGSize(width: 0.82, height: 1.22)
                vm.tug = 2
            }
            // Strain.
            for _ in 0..<7 {
                withAnimation(.linear(duration: 0.04)) { jitter = .random(in: -1.6...1.6) }
                guard await wait(0.045) else { return false }
            }
            withAnimation(.linear(duration: 0.04)) { jitter = 0 }
            // The notch snaps it back.
            withAnimation(.spring(response: 0.38, dampingFraction: 0.38)) {
                drop = 0
                squash = CGSize(width: 1.15, height: 0.88)
                vm.tug = 0
            }
            guard await wait(0.25) else { return false }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { squash = CGSize(width: 1, height: 1) }
            guard await wait(0.2) else { return false }
        }

        withAnimation(.easeIn(duration: 0.2)) { neck = 0 }
        return true
    }

    // MARK: Nudge

    /// Something needs you: come out right under the notch, get excited, and pull on it.
    private func nudge() async {
        x = 0
        mood = .wide
        look = CGVector(dx: 0, dy: -1)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { visible = true }
        withAnimation(.easeOut(duration: 0.1)) { squash = CGSize(width: 1.3, height: 0.7) }
        guard await wait(0.12) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.4)) { squash = CGSize(width: 1, height: 1) }
        guard await wait(0.5) else { return }

        while true {
            // Excited bounces, looking at you.
            look = nil
            mood = .wide
            for _ in 0..<2 {
                withAnimation(.easeOut(duration: 0.13)) { hop = 9; squash = CGSize(width: 0.85, height: 1.2) }
                guard await wait(0.13) else { return }
                withAnimation(.easeIn(duration: 0.12)) { hop = 0; squash = CGSize(width: 1, height: 1) }
                guard await wait(0.12) else { return }
                withAnimation(.easeOut(duration: 0.06)) { squash = CGSize(width: 1.25, height: 0.78) }
                guard await wait(0.06) else { return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { squash = CGSize(width: 1, height: 1) }
                guard await wait(0.1) else { return }
            }
            // Wiggle: "hey, over here!"
            for angle in [-18.0, 18, -14, 10, 0] {
                withAnimation(.easeInOut(duration: 0.09)) { lean = angle }
                guard await wait(0.09) else { return }
            }
            // Grab the notch and pull, hard.
            look = CGVector(dx: 0, dy: -1)
            withAnimation(.easeInOut(duration: 0.25)) { x = .random(in: -14...14) }
            guard await wait(0.25) else { return }
            guard await pull(times: 2, strength: 1.25) else { return }
            look = nil
            mood = .normal
            withAnimation(.easeInOut(duration: 0.3)) { x = 0 }
            // Catch its breath, watching you.
            guard await wait(2.2) else { return }
        }
    }
}

/// Orbit's speech bubble: what needs you, in the colour of the thing.
private struct NudgeBubble: View {
    let attention: Attention
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: attention.symbol).font(.system(size: 9, weight: .bold))
            Text(attention.label).font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(attention.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black))
        .overlay(Capsule().stroke(attention.tint.opacity(pulse ? 0.7 : 0.25), lineWidth: 1))
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
    }
}

/// A gooey strand of notch, wide where it leaves the pill and thin where Orbit holds it.
private struct GooNeck: Shape {
    func path(in r: CGRect) -> Path {
        let mid = r.midX, top = r.width, bottom: CGFloat = 5, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: mid - top / 2, y: 0))
        p.addQuadCurve(to: CGPoint(x: mid - bottom / 2, y: h), control: CGPoint(x: mid - bottom / 2, y: h * 0.3))
        p.addLine(to: CGPoint(x: mid + bottom / 2, y: h))
        p.addQuadCurve(to: CGPoint(x: mid + top / 2, y: 0), control: CGPoint(x: mid + bottom / 2, y: h * 0.3))
        p.closeSubpath()
        return p
    }
}
