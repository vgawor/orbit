import AppKit
import SwiftUI

/// Teleprompter right under the camera: your words scroll up with the current line
/// near the top of the panel, so your eyes stay close to the lens.
/// Text and settings are saved to ~/Library/Application Support/Orbit/prompter.json.
@MainActor
@Observable
final class PrompterModule: NotchModule {
    let id = "prompter"
    let title = "Prompter"
    let symbol = "text.alignleft"

    struct Saved: Codable {
        var text: String
        var wpm: Double
        var fontSize: Double
        var mirrored: Bool
    }

    static let wpmRange: ClosedRange<Double> = 80...220
    static let fontRange: ClosedRange<Double> = 14...34

    var text: String { didSet { if text != oldValue { restart(); scheduleSave() } } }
    var wpm: Double { didSet { rebase(oldWPM: oldValue); scheduleSave() } }
    var fontSize: Double { didSet { scheduleSave() } }
    var mirrored: Bool { didSet { scheduleSave() } }
    var isEditing: Bool

    private(set) var isPlaying = false
    /// Words read when play last started (or was paused).
    private var baseWords: Double = 0
    private var playStartedAt: Date?
    private var endTimer: Timer?
    private var saveTask: Task<Void, Never>?

    init() {
        let s = Storage.load(Saved.self, from: "prompter")
        text = s?.text ?? ""
        wpm = s?.wpm ?? 140
        fontSize = s?.fontSize ?? 22
        mirrored = s?.mirrored ?? false
        isEditing = (s?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var words: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }

    /// How many words have scrolled past at `date` (fractional for smooth motion).
    func position(at date: Date) -> Double {
        var p = baseWords
        if let playStartedAt { p += date.timeIntervalSince(playStartedAt) * wpm / 60 }
        return min(max(0, p), Double(wordCount))
    }

    var progress: Double { wordCount == 0 ? 0 : position(at: .now) / Double(wordCount) }

    // MARK: Controls

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard wordCount > 0 else { isEditing = true; return }
        if position(at: .now) >= Double(wordCount) { baseWords = 0 }
        isEditing = false
        playStartedAt = .now
        isPlaying = true
        endTimer?.invalidate()
        endTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                if self.position(at: .now) >= Double(self.wordCount) { self.pause() }
            }
        }
    }

    func pause() {
        baseWords = position(at: .now)
        playStartedAt = nil
        isPlaying = false
        endTimer?.invalidate()
        endTimer = nil
    }

    func restart() {
        let wasPlaying = isPlaying
        pause()
        baseWords = 0
        if wasPlaying { play() }
    }

    /// Jump by a number of words (negative goes back).
    func skip(_ n: Double) {
        let wasPlaying = isPlaying
        pause()
        baseWords = min(max(0, baseWords + n), Double(wordCount))
        if wasPlaying { play() }
    }

    func faster() { wpm = min(Self.wpmRange.upperBound, wpm + 10) }
    func slower() { wpm = max(Self.wpmRange.lowerBound, wpm - 10) }

    func edit() { pause(); isEditing = true }

    /// Keeps the current spot when the speed changes mid-play.
    private func rebase(oldWPM: Double) {
        guard let start = playStartedAt else { return }
        baseWords += Date.now.timeIntervalSince(start) * oldWPM / 60
        playStartedAt = .now
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.save()
        }
    }

    private func save() {
        Storage.save(Saved(text: text, wpm: wpm, fontSize: fontSize, mirrored: mirrored), to: "prompter")
    }

    func stop() {
        pause()
        saveTask?.cancel()
        save()
    }

    // MARK: Views

    var peekChip: PeekChip? {
        guard isPlaying else { return nil }
        return PeekChip(symbol: "text.alignleft", text: "Prompter", tint: Tokens.live, priority: 3)
    }

    var panel: AnyView { AnyView(PrompterPanel(module: self)) }
}

// MARK: - Panel

struct PrompterPanel: View {
    let module: PrompterModule

    var body: some View {
        VStack(spacing: 8) {
            if module.isEditing {
                PrompterEditor(module: module)
            } else {
                PrompterScroller(module: module)
            }
            PrompterControls(module: module)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(KeyDownMonitor { e in
            // Space toggles play, ↑/↓ change speed; only while reading (not while typing).
            guard !module.isEditing else { return false }
            switch e.keyCode {
            case 49: module.toggle(); return true
            case 126: module.faster(); return true
            case 125: module.slower(); return true
            case 123: module.skip(-8); return true
            case 124: module.skip(8); return true
            default: return false
            }
        })
    }
}

private struct PrompterEditor: View {
    let module: PrompterModule

    var body: some View {
        @Bindable var module = module
        ZStack(alignment: .topLeading) {
            TextEditor(text: $module.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
            if module.text.isEmpty {
                Text("Paste or type what you want to say…")
                    .font(.system(size: 13)).foregroundStyle(Tokens.faint)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Tokens.stroke))
    }
}

/// The reading view: lines laid out to the panel width, scrolled so the current line
/// sits near the top (closest to the camera), with soft fades at both edges.
private struct PrompterScroller: View {
    let module: PrompterModule

    struct Line { let text: String; let start: Int; let count: Int }

    var body: some View {
        GeometryReader { geo in
            let font = CGFloat(module.fontSize)
            let width = geo.size.width - 32
            let lines = Self.layout(module.words, width: width, fontSize: font)
            let lineHeight = font * 1.45
            let anchor = lineHeight * 0.9 // current line's center, near the top

            TimelineView(.animation(paused: !module.isPlaying)) { context in
                let pos = module.position(at: context.date)
                let current = Self.lineIndex(for: pos, in: lines)
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let d = abs(Double(i) - current)
                        Text(line.text)
                            .font(.system(size: font, weight: d < 0.5 ? .semibold : .medium))
                            .foregroundStyle(.white.opacity(max(0.22, 1 - d * 0.32)))
                            .scaleEffect(1 - min(d, 1.5) * 0.08, anchor: .center)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(width: width, height: lineHeight)
                    }
                }
                .frame(width: geo.size.width)
                .offset(y: anchor - lineHeight / 2 - current * lineHeight)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .clipped()
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.08),
                    .init(color: .black, location: 0.55),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .scaleEffect(x: module.mirrored ? -1 : 1, y: 1)
            .overlay(alignment: .bottom) {
                // Thin progress bar.
                GeometryReader { g in
                    TimelineView(.animation(minimumInterval: 0.25, paused: !module.isPlaying)) { _ in
                        Capsule().fill(Tokens.live.opacity(0.7))
                            .frame(width: g.size.width * module.progress, height: 2)
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture { module.toggle() }
    }

    /// Fractional line index for a word position, so scrolling is continuous.
    static func lineIndex(for pos: Double, in lines: [Line]) -> Double {
        guard !lines.isEmpty else { return 0 }
        for (i, l) in lines.enumerated() where pos < Double(l.start + l.count) {
            return Double(i) + (pos - Double(l.start)) / Double(max(1, l.count))
        }
        return Double(lines.count - 1) + 1
    }

    /// Greedy word wrap using real text widths.
    static func layout(_ words: [String], width: CGFloat, fontSize: CGFloat) -> [Line] {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let space = (" " as NSString).size(withAttributes: attrs).width
        var lines: [Line] = []
        var current: [String] = []
        var currentWidth: CGFloat = 0
        var start = 0
        for (i, w) in words.enumerated() {
            let ww = (w as NSString).size(withAttributes: attrs).width
            if !current.isEmpty, currentWidth + space + ww > width {
                lines.append(Line(text: current.joined(separator: " "), start: start, count: current.count))
                current = []; currentWidth = 0; start = i
            }
            currentWidth += (current.isEmpty ? 0 : space) + ww
            current.append(w)
        }
        if !current.isEmpty { lines.append(Line(text: current.joined(separator: " "), start: start, count: current.count)) }
        return lines
    }
}

private struct PrompterControls: View {
    let module: PrompterModule

    var body: some View {
        @Bindable var module = module
        HStack(spacing: 10) {
            if module.isEditing {
                PillButton(title: "Start") { module.play() }
                Text("\(module.wordCount) words · ~\(minutesText)")
                    .font(.system(size: 11)).foregroundStyle(Tokens.secondary)
            } else {
                IconButton(symbol: module.isPlaying ? "pause.fill" : "play.fill", size: 14) { module.toggle() }
                IconButton(symbol: "arrow.counterclockwise", size: 12) { module.restart() }
                IconButton(symbol: "pencil", size: 12) { module.edit() }
            }
            Spacer(minLength: 4)
            Image(systemName: "tortoise").font(.system(size: 10)).foregroundStyle(Tokens.faint)
            Slider(value: $module.wpm, in: PrompterModule.wpmRange, step: 5)
                .controlSize(.mini).frame(width: 110)
            Image(systemName: "hare").font(.system(size: 10)).foregroundStyle(Tokens.faint)
            Text("\(Int(module.wpm)) wpm")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Tokens.secondary)
                .frame(width: 52, alignment: .leading)
            IconButton(symbol: "textformat.size.smaller", size: 11) {
                module.fontSize = max(PrompterModule.fontRange.lowerBound, module.fontSize - 2)
            }
            IconButton(symbol: "textformat.size.larger", size: 11) {
                module.fontSize = min(PrompterModule.fontRange.upperBound, module.fontSize + 2)
            }
            IconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", size: 11) {
                module.mirrored.toggle()
            }
            .foregroundStyle(module.mirrored ? Tokens.live : .white)
            .help("Mirror")
        }
        .frame(height: 28)
    }

    private var minutesText: String {
        let m = Double(module.wordCount) / module.wpm
        return m < 1 ? "\(Int((m * 60).rounded())) s" : String(format: "%.1f min", m)
    }
}
