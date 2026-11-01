import AppKit
import SwiftUI

// Shared pieces for the AI add-ons: one Claude call with state and cancel, the clipboard,
// and the small views every AI panel uses (input box, working, no key, result, error).

/// Runs one Claude request at a time and keeps its state for the view.
@MainActor
@Observable
final class AIRequest {
    enum Phase: Equatable {
        case idle
        case working
        case done(String)
        case failed(String)
    }

    var phase: Phase = .idle
    private var task: Task<Void, Never>?

    var isWorking: Bool { phase == .working }
    var result: String? { if case .done(let text) = phase { text } else { nil } }

    /// Sends one user message. `onDone` gets the reply text (on the main actor) and returns what to show.
    func run(system: String, message: String, maxTokens: Int = 2000, onDone: ((String) -> String)? = nil) {
        task?.cancel()
        phase = .working
        task = Task { [weak self] in
            do {
                let json = try await ClaudeAPI.send(system: system, messages: [["role": "user", "content": message]],
                                                    effort: "low", maxTokens: maxTokens)
                guard !Task.isCancelled, let self else { return }
                let text = ClaudeAPI.text(json["content"] as? [[String: Any]] ?? [])
                if text.isEmpty {
                    self.phase = .failed("Claude didn't return any text. Try again.")
                } else {
                    self.phase = .done(onDone?(text) ?? text)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func reset() { cancel() }

    /// Layout snapshots only: show a finished answer without calling Claude.
    func preview(_ text: String) { phase = .done(text) }
}

enum AIClipboard {
    @MainActor static func read() -> String? {
        NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor static func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Views

/// A text box with a placeholder and "Use clipboard" / "Clear" under it.
struct AIInputBox<Trailing: View>: View {
    @Binding var text: String
    var placeholder: String
    var label: String = "Text"
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardLabel(label)
                Spacer(minLength: 0)
                if !text.isEmpty {
                    Text("\(text.count) characters").font(.system(size: 10.5)).foregroundStyle(Tokens.faint)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5).padding(.vertical, 6)
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 12.5)).foregroundStyle(Tokens.faint)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Tokens.stroke))
            HStack(spacing: 6) {
                GlassPillButton(title: "Use clipboard", symbol: "doc.on.clipboard") {
                    if let clip = AIClipboard.read(), !clip.isEmpty { text = clip }
                }
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).glassSurface(Circle(), interactive: true).contentShape(Circle())
                    }
                    .buttonStyle(.plain).help("Clear")
                }
                Spacer(minLength: 0)
                trailing
            }
        }
    }
}

/// Selectable chips (lengths, tones). One is picked.
struct AIChips<Item: Identifiable & Equatable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                let on = item == selection
                Button { selection = item } label: {
                    Text(title(item))
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? .white : Tokens.secondary)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassSurface(Capsule(), selected: on, interactive: true)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Orbit, the assistant

/// What Orbit acts out next to it: one little prop per AI add-on.
enum AIScene: String, CaseIterable {
    case prompt       // a prompt card being typed
    case summarize    // a long page squeezed into three bullets
    case translate    // two language bubbles swapping places
    case rewrite      // a pencil writing a fresh line under a crossed-out one
    case actionItems  // boxes ticked one by one
    case connect      // a key: Claude isn't connected yet

    /// What the working view says while Claude works.
    var workingText: String {
        switch self {
        case .prompt: "Orbit is asking Claude…"
        case .summarize: "Orbit is squeezing it down…"
        case .translate: "Orbit is translating…"
        case .rewrite: "Orbit is rewriting…"
        case .actionItems: "Orbit is reading your notes…"
        case .connect: "Connecting…"
        }
    }
}

/// Orbit with its prop. While `busy`, Orbit thinks (the moon circles) with a typing bubble
/// and the prop acts out the job; otherwise Orbit idles and the prop plays its loop gently.
struct AIOrbitScene: View {
    let scene: AIScene
    var busy = false
    var size: CGFloat = 46
    var mood: OrbitView.Mood = .normal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = reduceMotion
        HStack(alignment: .center, spacing: size * 0.1) {
            OrbitView(size: size, mood: mood, motion: busy ? .thinking : .idle,
                      gaze: busy ? nil : CGVector(dx: 0.9, dy: 0.2))
                .overlay(alignment: .topTrailing) {
                    if busy {
                        AITypingBubble(width: size * 0.5)
                            .offset(x: size * 0.18, y: -size * 0.3)
                    }
                }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { timeline in
                // Busy props run quicker; a still pose shows the finished job.
                let t = timeline.date.timeIntervalSinceReferenceDate * (busy ? 1.4 : 1)
                Canvas { ctx, canvas in
                    AIProp.draw(scene, in: &ctx, size: canvas, t: t, still: still)
                }
            }
            .frame(width: size * 1.05, height: size * 0.95)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Orbit")
    }
}

/// Three dots bouncing in a small speech bubble.
struct AITypingBubble: View {
    var width: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, canvas in
                let w = canvas.width, h = canvas.height * 0.78
                var bubble = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: h / 2)
                bubble.move(to: CGPoint(x: w * 0.2, y: h - 1))
                bubble.addLine(to: CGPoint(x: w * 0.12, y: canvas.height))
                bubble.addLine(to: CGPoint(x: w * 0.38, y: h - 1))
                ctx.fill(bubble, with: .color(.white))
                let r = w * 0.075
                for i in 0..<3 {
                    let bounce = reduceMotion ? 0 : max(0, sin((t * 2 * .pi / 1.1) - Double(i) * 0.9)) * h * 0.16
                    let x = w * (0.28 + Double(i) * 0.22)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: h / 2 - r - bounce, width: r * 2, height: r * 2)),
                             with: .color(.black.opacity(0.55)))
                }
            }
        }
        .frame(width: width, height: width * 0.62)
    }
}

/// The props, drawn from the clock in a 100×90 design so many of them stay cheap.
enum AIProp {
    static var accent: Color { AddOnCategory.ai.tint }
    static let paper = Color.white.opacity(0.92)
    static let ink = Color.black.opacity(0.3)

    static func draw(_ scene: AIScene, in ctx: inout GraphicsContext, size: CGSize, t: Double, still: Bool) {
        let u = min(size.width / 100, size.height / 90)
        ctx.translateBy(x: (size.width - 100 * u) / 2, y: (size.height - 90 * u) / 2)
        ctx.scaleBy(x: u, y: u)
        switch scene {
        case .prompt: prompt(&ctx, t: t, still: still)
        case .summarize: summarize(&ctx, t: t, still: still)
        case .translate: translate(&ctx, t: t, still: still)
        case .rewrite: rewrite(&ctx, t: t, still: still)
        case .actionItems: actionItems(&ctx, t: t, still: still)
        case .connect: key(&ctx, t: t, still: still)
        }
    }

    // 0…1 inside [a, b], eased.
    static func ramp(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let v = min(max((x - a) / (b - a), 0), 1)
        return v * v * (3 - 2 * v)
    }

    private static func line(_ ctx: GraphicsContext, _ x0: Double, _ x1: Double, _ y: Double,
                             _ color: Color = ink, width: Double = 4.5) {
        guard x1 > x0 + 0.5 else { return }
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// A prompt card: a {…} tag and lines typed one after another, with a caret.
    private static func prompt(_ ctx: inout GraphicsContext, t: Double, still: Bool) {
        let c = still ? 0.99 : t.truncatingRemainder(dividingBy: 3.2) / 3.2
        let card = CGRect(x: 14, y: 8, width: 72, height: 74)
        ctx.fill(Path(roundedRect: card, cornerRadius: 11), with: .color(paper))
        let tag = Path(roundedRect: CGRect(x: 22, y: 16, width: 26, height: 13), cornerRadius: 6.5)
        ctx.fill(tag, with: .color(accent))
        ctx.draw(Text("{ }").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white), at: CGPoint(x: 35, y: 22.5))
        let widths = [52.0, 44, 30]
        var caret = CGPoint(x: 24, y: 41)
        for (i, w) in widths.enumerated() {
            let p = ramp(c, 0.08 + Double(i) * 0.26, 0.3 + Double(i) * 0.26)
            let y = 41 + Double(i) * 13
            line(ctx, 24, 24 + w * p, y)
            if p > 0 { caret = CGPoint(x: 24 + w * p + 5, y: y) }
        }
        if still || Int(t * 2.4) % 2 == 0 { line(ctx, caret.x, caret.x + 0.6, caret.y, accent, width: 5) }
    }

    /// A long page squeezed from the top and bottom until three bullets are left.
    private static func summarize(_ ctx: inout GraphicsContext, t: Double, still: Bool) {
        let c = t.truncatingRemainder(dividingBy: 3.4) / 3.4
        let k = still ? 1 : ramp(c, 0.18, 0.5) * (1 - ramp(c, 0.84, 1))
        let top = 4 + 26 * k, bottom = 86 - 14 * k
        let page = CGRect(x: 20, y: top, width: 60, height: bottom - top)
        ctx.fill(Path(roundedRect: page, cornerRadius: 8), with: .color(paper))
        // Six long lines fade out as the page shrinks…
        if k < 0.5 {
            var lines = ctx
            lines.opacity = 1 - k * 2
            for i in 0..<6 {
                let y = top + 10 + Double(i) * (page.height - 20) / 5
                line(lines, 28, i % 3 == 2 ? 58 : 72, y)
            }
        }
        // …and three bullets take their place.
        if k > 0.5 {
            var bullets = ctx
            bullets.opacity = (k - 0.5) * 2
            for i in 0..<3 {
                let y = top + 12 + Double(i) * (page.height - 24) / 2
                bullets.fill(Path(ellipseIn: CGRect(x: 27, y: y - 3, width: 6, height: 6)), with: .color(accent))
                line(bullets, 39, i == 1 ? 62 : 70, y)
            }
        }
        // Little chevrons pressing in from above and below.
        let press = k * 6
        for (y, dir) in [(top - 3 - press, 1.0), (bottom + 3 + press, -1.0)] where k > 0.05 && !still {
            var v = Path()
            v.move(to: CGPoint(x: 43, y: y - 4 * dir)); v.addLine(to: CGPoint(x: 50, y: y)); v.addLine(to: CGPoint(x: 57, y: y - 4 * dir))
            ctx.stroke(v, with: .color(.white.opacity(0.7 * k)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }

    /// Two speech bubbles ("A" and "あ") circling round each other to swap sides.
    private static func translate(_ ctx: inout GraphicsContext, t: Double, still: Bool) {
        let c = t.truncatingRemainder(dividingBy: 4.4) / 4.4
        let s = still ? 0 : ramp(c, 0.2, 0.45) + ramp(c, 0.7, 0.95)
        let a = s * .pi
        struct Bubble { var x: Double; var y: Double; var depth: Double; var glyph: String; var fill: Color; var text: Color; var tailLeft: Bool }
        let one = Bubble(x: 50 - 24 * cos(a), y: 44 + 10 * sin(a), depth: sin(a), glyph: "A", fill: paper, text: .black.opacity(0.75), tailLeft: true)
        let two = Bubble(x: 50 + 24 * cos(a), y: 44 - 10 * sin(a), depth: -sin(a), glyph: "あ", fill: accent, text: .white, tailLeft: false)
        for b in [one, two].sorted(by: { $0.depth < $1.depth }) {
            let scale = 1 + 0.1 * b.depth
            let w = 40 * scale, h = 32 * scale
            let rect = CGRect(x: b.x - w / 2, y: b.y - h / 2, width: w, height: h)
            var p = Path(roundedRect: rect, cornerRadius: 10 * scale)
            let tx = b.tailLeft ? rect.minX + w * 0.28 : rect.maxX - w * 0.28
            p.move(to: CGPoint(x: tx - 5, y: rect.maxY - 1))
            p.addLine(to: CGPoint(x: tx + (b.tailLeft ? -5 : 5), y: rect.maxY + 8 * scale))
            p.addLine(to: CGPoint(x: tx + 5, y: rect.maxY - 1))
            var layer = ctx
            layer.opacity = 0.75 + 0.25 * (b.depth + 1) / 2
            layer.fill(p, with: .color(b.fill))
            layer.draw(Text(b.glyph).font(.system(size: 17 * scale, weight: .bold, design: .rounded)).foregroundStyle(b.text),
                       at: CGPoint(x: b.x, y: b.y))
        }
    }

    /// A crossed-out line, and a pencil writing a fresh wavy one under it.
    private static func rewrite(_ ctx: inout GraphicsContext, t: Double, still: Bool) {
        let c = t.truncatingRemainder(dividingBy: 2.8) / 2.8
        let p = still ? 1 : ramp(c, 0.05, 0.75)
        line(ctx, 10, 66, 26, .white.opacity(0.35))
        line(ctx, 8, 70, 26, accent.opacity(0.9), width: 3)
        // The new line, written so far.
        func wave(_ x: Double) -> CGPoint { CGPoint(x: x, y: 58 + 5 * sin(x * 0.22)) }
        let x0 = 10.0, x1 = 86.0, xEnd = x0 + (x1 - x0) * p
        if xEnd > x0 + 1 {
            var path = Path()
            path.move(to: wave(x0))
            var x = x0
            while x < xEnd { x = min(x + 2, xEnd); path.addLine(to: wave(x)) }
            ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        // The pencil, tip on the end of the line, leaning right; it lifts a little at the end.
        let tip = wave(xEnd)
        var pen = ctx
        pen.translateBy(x: tip.x, y: tip.y - 6 * ramp(c, 0.78, 0.9) * (still ? 0 : 1))
        pen.rotate(by: .degrees(-50))
        // Drawn pointing along +x from the tip.
        var cone = Path()
        cone.move(to: .zero); cone.addLine(to: CGPoint(x: 11, y: -5.5)); cone.addLine(to: CGPoint(x: 11, y: 5.5)); cone.closeSubpath()
        pen.fill(cone, with: .color(Color(red: 0.98, green: 0.86, blue: 0.68)))
        pen.fill(Path(ellipseIn: CGRect(x: -1, y: -2, width: 4.5, height: 4)), with: .color(.black.opacity(0.75)))
        pen.fill(Path(CGRect(x: 11, y: -5.5, width: 30, height: 11)), with: .color(accent))
        pen.fill(Path(CGRect(x: 41, y: -5.5, width: 5, height: 11)), with: .color(.white.opacity(0.85)))
        pen.fill(Path(roundedRect: CGRect(x: 46, y: -5.5, width: 8, height: 11), cornerRadius: 3),
                 with: .color(Color(red: 1, green: 0.55, blue: 0.62)))
    }

    /// Three boxes ticked one by one; still, the first two are done.
    private static func actionItems(_ ctx: inout GraphicsContext, t: Double, still: Bool) {
        let c = t.truncatingRemainder(dividingBy: 3.4) / 3.4
        for i in 0..<3 {
            let y = 18 + Double(i) * 27
            let tick = still ? (i < 2 ? 1 : 0) : ramp(c, 0.12 + Double(i) * 0.22, 0.24 + Double(i) * 0.22) * (1 - ramp(c, 0.9, 1))
            let box = CGRect(x: 10, y: y - 9, width: 18, height: 18)
            ctx.stroke(Path(roundedRect: box, cornerRadius: 5), with: .color(.white.opacity(0.6)), lineWidth: 2.5)
            if tick > 0.01 {
                var on = ctx
                on.opacity = min(tick * 1.6, 1)
                on.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(accent))
                var check = Path()
                check.move(to: CGPoint(x: 14.5, y: y + 0.5))
                check.addLine(to: CGPoint(x: 18, y: y + 4))
                check.addLine(to: CGPoint(x: 24, y: y - 4))
                on.stroke(check.trimmedPath(from: 0, to: tick), with: .color(.white),
                          style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
            }
            line(ctx, 38, i == 1 ? 74 : 88, y, .white.opacity(tick > 0.5 ? 0.4 : 0.75))
        }
    }

    /// A key, rocking gently.
    private static func key(_ ctx: inout GraphicsContext, t: Double, still: Bool) {
        var k = ctx
        k.translateBy(x: 50, y: 45)
        k.rotate(by: .degrees(-24 + (still ? 0 : 6 * sin(t * 2 * .pi / 2.6))))
        let gold = Color(red: 1, green: 0.8, blue: 0.35)
        k.stroke(Path(ellipseIn: CGRect(x: -38, y: -13, width: 26, height: 26)), with: .color(gold), lineWidth: 7)
        var shaft = Path()
        shaft.move(to: CGPoint(x: -12, y: 0)); shaft.addLine(to: CGPoint(x: 38, y: 0))
        shaft.move(to: CGPoint(x: 26, y: 0)); shaft.addLine(to: CGPoint(x: 26, y: 11))
        shaft.move(to: CGPoint(x: 35, y: 0)); shaft.addLine(to: CGPoint(x: 35, y: 9))
        k.stroke(shaft, with: .color(gold), style: StrokeStyle(lineWidth: 7, lineCap: .round))
    }
}

// MARK: - States

/// Orbit thinking with its prop, a line and Cancel.
struct AIWorkingView: View {
    var scene: AIScene = .prompt
    var text: String? = nil
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            AIOrbitScene(scene: scene, busy: true)
            Text(text ?? scene.workingText).font(.system(size: 12.5)).foregroundStyle(Tokens.secondary)
            GlassPillButton(title: "Cancel", symbol: "stop.fill", action: cancel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown instead of a result when there's no Claude API key: Orbit holding out a key.
struct AINoKeyView: View {
    var compact = false

    var body: some View {
        VStack(spacing: 10) {
            AIOrbitScene(scene: .connect, size: compact ? 34 : 44, mood: .wide)
            VStack(spacing: 3) {
                Text("Connect Claude").font(.system(size: 13.5, weight: .semibold))
                Text("Orbit needs your Claude API key. Add it in Settings → Accounts.")
                    .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            SettingsLink {
                Text("Open Settings").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 13).padding(.vertical, 6)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { SettingsWindow.willOpen() })
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A plain-words error with "Try again". Orbit looks grumpy about it.
struct AIErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            OrbitView(size: 38, mood: .grumpy, motion: .idle)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(.white, Tokens.error)
                        .offset(x: 6, y: -4)
                }
            Text(message).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            GlassPillButton(title: "Try again", symbol: "arrow.clockwise", action: retry)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An empty result area: Orbit with its prop, and a hint.
struct AIHintView: View {
    let scene: AIScene
    let text: String
    var mood: OrbitView.Mood = .normal

    var body: some View {
        VStack(spacing: 12) {
            AIOrbitScene(scene: scene, mood: mood)
            Text(text).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Scrolling, selectable result text.
struct AIResultText: View {
    let text: String

    var body: some View {
        NotchScroll {
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The label over a finished answer, with a small happy Orbit presenting it.
struct AIResultLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            OrbitView(size: 18, mood: .happy, motion: .idle)
            CardLabel(text)
        }
    }
}

/// "Copied" feedback for a copy button: shows a check for a moment.
struct AICopyButton: View {
    var title = "Copy"
    let text: () -> String
    @State private var copied = false

    var body: some View {
        GlassPillButton(title: copied ? "Copied" : title, symbol: copied ? "checkmark" : "doc.on.doc") {
            AIClipboard.write(text())
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
        }
    }
}

/// The right-hand result card shared by Summarize, Translate and Rewrite: picks the right state.
struct AIResultCard<Actions: View, Header: View>: View {
    let request: AIRequest
    let label: String
    let scene: AIScene
    let hint: String
    let retry: () -> Void
    @ViewBuilder var header: (String) -> Header
    @ViewBuilder var actions: (String) -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch request.phase {
            case .working:
                AIWorkingView(scene: scene) { request.cancel() }
            case .failed(let message):
                AIErrorView(message: message, retry: retry)
            case .done(let text):
                HStack(spacing: 6) { AIResultLabel(text: label); Spacer(minLength: 0); header(text) }
                AIResultText(text: text)
                    .frame(maxHeight: .infinity, alignment: .top)
                HStack(spacing: 6) { actions(text) }
            case .idle:
                if ClaudeAPI.isConfigured { AIHintView(scene: scene, text: hint) } else { AINoKeyView() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(18)
    }
}

extension AIResultCard where Header == EmptyView {
    init(request: AIRequest, label: String, scene: AIScene, hint: String, retry: @escaping () -> Void,
         @ViewBuilder actions: @escaping (String) -> Actions) {
        self.init(request: request, label: label, scene: scene, hint: hint, retry: retry,
                  header: { _ in EmptyView() }, actions: actions)
    }
}

// MARK: - Home cards

extension AIRequest.Phase {
    /// One line for a Home card: what's happening, the start of the answer, or `idle`.
    func homeLine(idle: String) -> String {
        switch self {
        case .idle: idle
        case .working: "Working on it…"
        case .done(let text): AILogic.previewLine(text) ?? idle
        case .failed: "That didn't work. Open to try again."
        }
    }
}

/// A compact Home card for an AI add-on: Orbit acting out the job, a title, one status line
/// and the add-on's own buttons. Clicking the card (outside the buttons) opens the panel.
/// Nothing here calls Claude on its own; the buttons do, when clicked.
struct AIHomeCard<Actions: View>: View {
    let scene: AIScene
    let label: String
    let title: String
    let line: String
    var busy = false
    var mood: OrbitView.Mood = .normal
    let open: () -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        NotchCard {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(label)
                HStack(spacing: 10) {
                    AIOrbitScene(scene: scene, busy: busy, size: 32, mood: mood)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(line).font(.system(size: 11)).foregroundStyle(Tokens.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    actions
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

/// "Clipboard → English": what a Home card's button does, as its title.
func aiClipboardTitle(_ target: String) -> String { "Clipboard → \(target)" }

/// A round icon button for a Home card (copy the answer, replace the clipboard…) that shows a check for a moment.
struct AIHomeIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var done = false

    var body: some View {
        Button {
            action()
            done = true
            Task { try? await Task.sleep(for: .seconds(1.4)); done = false }
        } label: {
            Image(systemName: done ? "checkmark" : symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(done ? Tokens.live : .white)
                .frame(width: 28, height: 28)
                .glassSurface(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Copies an answer from a Home card.
struct AIHomeCopyButton: View {
    let text: String
    var body: some View {
        AIHomeIconButton(symbol: "doc.on.doc", help: "Copy the answer") { AIClipboard.write(text) }
    }
}

/// A Home-card button that works on the clipboard. Shows "Copy some text first" when it's empty
/// and opens the panel when Claude isn't connected.
struct AIClipboardButton: View {
    let title: String
    /// Runs the job; returns false when the clipboard had no text.
    let run: () -> Bool
    let open: () -> Void
    @State private var empty = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            guard ClaudeAPI.isConfigured else { open(); return }
            if !run() {
                empty = true
                Task { try? await Task.sleep(for: .seconds(1.6)); empty = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: empty ? "exclamationmark.circle" : "doc.on.clipboard").font(.system(size: 11, weight: .semibold))
                Text(empty ? "Clipboard empty" : title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.white))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .fixedSize()
        .help("Uses the text on your clipboard")
    }
}
