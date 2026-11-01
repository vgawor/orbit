import SwiftUI

/// Timer & Focus.
/// - Timers: as many countdowns as you like at once ("Tea 5 min", "Laundry 45 min"), each with
///   its own pause and stop. Presets are yours to change.
/// - Focus: one focus session at a time, either a single block (e.g. 50 min) or a focus cycle:
///   rounds of focus with short breaks, flowing automatically or one step at a time.
///   Your time is a ring of dots; breaks are orange; your companion cheers you on.
///   The focus playlist (Spotify) plays only during focus.
@MainActor
@Observable
final class FocusModule: NotchModule {
    let id = "focus"
    let title = "Timer & Focus"
    let symbol = "timer"

    // MARK: Settings (yours to change)

    private static let ud = UserDefaults.standard
    /// Timer buttons, in minutes.
    var timerPresets: [Int] = ud.array(forKey: "timer.presets") as? [Int] ?? [5, 15] {
        didSet { Self.ud.set(timerPresets, forKey: "timer.presets") }
    }
    /// A single focus block.
    var singleFocusMinutes = ud.object(forKey: "focus.single") as? Int ?? 50 {
        didSet { Self.ud.set(singleFocusMinutes, forKey: "focus.single") }
    }
    /// Focus cycle: focus length, break length and number of rounds.
    var cycleFocusMinutes = ud.object(forKey: "focus.cycleFocus") as? Int ?? 25 {
        didSet { Self.ud.set(cycleFocusMinutes, forKey: "focus.cycleFocus") }
    }
    var breakMinutes = ud.object(forKey: "focus.break") as? Int ?? 5 {
        didSet { Self.ud.set(breakMinutes, forKey: "focus.break") }
    }
    var rounds = ud.object(forKey: "focus.rounds") as? Int ?? 4 {
        didSet { Self.ud.set(rounds, forKey: "focus.rounds") }
    }
    /// Automatic: rounds and breaks flow on their own. Manual: you start each break and round.
    var automatic = ud.object(forKey: "focus.automatic") as? Bool ?? true {
        didSet { Self.ud.set(automatic, forKey: "focus.automatic") }
    }

    // MARK: Timers (many at once)

    struct Countdown: Identifiable {
        let id = UUID()
        var label: String
        var minutes: Int
        var endsAt: Date
        /// Set while paused: the time that was left.
        var pausedRemaining: TimeInterval?

        var isPaused: Bool { pausedRemaining != nil }
        var total: TimeInterval { Double(minutes) * 60 }
        func remaining(at now: Date) -> TimeInterval { pausedRemaining ?? max(0, endsAt.timeIntervalSince(now)) }
    }

    private(set) var timers: [Countdown] = []
    /// Ticks twice a second while anything runs, so views can show live countdowns.
    private(set) var now = Date()

    /// Adds a countdown that runs alongside everything else.
    func startTimer(_ m: Int, label: String? = nil) {
        let minutes = min(max(m, 1), 24 * 60)
        let name = (label?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "\(minutes) min"
        timers.append(Countdown(label: name, minutes: minutes, endsAt: .now.addingTimeInterval(Double(minutes) * 60)))
        timers.sort { $0.remaining(at: .now) < $1.remaining(at: .now) }
        ensureTicking()
    }

    func toggleTimer(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        if let left = timers[i].pausedRemaining {
            timers[i].endsAt = .now.addingTimeInterval(left)
            timers[i].pausedRemaining = nil
        } else {
            timers[i].pausedRemaining = timers[i].remaining(at: .now)
        }
        ensureTicking()
    }

    func removeTimer(_ id: UUID) { timers.removeAll { $0.id == id } }

    /// The timer that ends first.
    var nextTimer: Countdown? { timers.filter { !$0.isPaused }.min { $0.endsAt < $1.endsAt } ?? timers.first }

    // MARK: Focus session (one at a time)

    enum Kind { case single, cycle }
    enum Phase { case focus, rest }
    enum Stage { case idle, running, paused, breakReady, focusReady }

    private(set) var kind: Kind = .cycle
    private(set) var phase: Phase = .focus
    private(set) var stage: Stage = .idle
    /// Length of the current focus block.
    private(set) var minutes = 25
    private(set) var round = 1
    private(set) var remaining: TimeInterval = 25 * 60
    private var endsAt: Date?

    private var timer: Timer?
    private let alerts: AlertCenter
    private weak var music: MusicModule?

    init(alerts: AlertCenter, music: MusicModule? = nil) {
        self.alerts = alerts
        self.music = music
        if let data = UserDefaults.standard.data(forKey: "focus.playlist") {
            playlist = try? JSONDecoder().decode(FocusPlaylist.self, from: data)
        }
        minutes = cycleFocusMinutes
        remaining = Double(minutes) * 60
    }

    var isRunning: Bool { stage == .running }
    var hasStarted: Bool { stage == .running || stage == .paused }
    var total: TimeInterval { Double(phase == .focus ? minutes : breakMinutes) * 60 }
    var fraction: Double { total > 0 ? remaining / total : 0 }

    var headline: String {
        switch stage {
        case .idle: return "Focus"
        case .breakReady: return "Time for a break"
        case .focusReady: return "Ready for round \(round)"
        case .running, .paused:
            if kind == .single { return "Focus · \(minutes) min" }
            return phase == .focus ? "Focus · Round \(round) of \(rounds)" : "Break"
        }
    }

    var detail: String {
        let dot = "Orbit"
        switch stage {
        case .idle: return "\(rounds) × \(cycleFocusMinutes) min with \(breakMinutes) min breaks, or one \(singleFocusMinutes) min block."
        case .paused: return "Paused"
        case .breakReady: return "\(dot): Good work. Take a break."
        case .focusReady: return "\(dot): Break's over. Ready when you are."
        case .running:
            if phase == .rest { return "\(dot): Good work. Take a \(breakMinutes)-minute break." }
            if kind == .single { return "Ends at \(Date.now.addingTimeInterval(remaining).formatted(.dateTime.hour().minute()))" }
            return automatic ? "Automatic" : "Manual"
        }
    }

    /// One focus block (e.g. 50 min), with the focus playlist.
    func startFocus(minutes m: Int? = nil) {
        kind = .single
        minutes = min(max(m ?? singleFocusMinutes, 1), 600)
        phase = .focus
        round = 1
        begin()
        musicStart()
    }

    /// Rounds of focus with breaks, with the focus playlist.
    func startCycle() {
        kind = .cycle
        minutes = cycleFocusMinutes
        phase = .focus
        round = 1
        begin()
        musicStart()
    }

    func pause() {
        guard stage == .running else { return }
        stage = .paused
        musicPause()
    }

    func resume() {
        guard stage == .paused else { return }
        run()
        if phase == .focus { musicResume() }
    }

    func stopSession() {
        musicPause()
        musicActive = false
        stage = .idle
        kind = .cycle
        phase = .focus
        minutes = cycleFocusMinutes
        round = 1
        remaining = total
        endsAt = nil
    }

    func startBreak() {
        phase = .rest
        musicPause()
        begin()
    }

    func startNextFocus() {
        phase = .focus
        begin()
        musicResume()
    }

    /// One button for Home and the peek.
    func toggle() {
        switch stage {
        case .idle: startCycle()
        case .running: pause()
        case .paused: resume()
        case .breakReady: startBreak()
        case .focusReady: startNextFocus()
        }
    }

    func stop() {
        stopSession()
        timers.removeAll()
    }

    private func begin() {
        remaining = total
        run()
    }

    private func run() {
        endsAt = .now.addingTimeInterval(remaining)
        stage = .running
        ensureTicking()
    }

    // MARK: Ticking

    private func ensureTicking() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        now = .now
        // Focus session
        if stage == .running, let endsAt {
            remaining = max(0, endsAt.timeIntervalSince(now))
            if remaining == 0 { finishPhase() }
        }
        // Timers
        for t in timers where !t.isPaused && t.remaining(at: now) == 0 {
            timers.removeAll { $0.id == t.id }
            alerts.post(NotchAlert(symbol: "timer", tint: Tokens.live, title: "\(t.label) is up",
                                   subtitle: "\(t.minutes)-minute timer", actions: [.init(title: "OK", isPrimary: true)],
                                   duration: 10, sound: "Glass"))
        }
        // Stop ticking when nothing runs
        if stage != .running && timers.allSatisfy(\.isPaused) {
            timer?.invalidate()
            timer = nil
        }
    }

    func finishPhase() {
        let dot = "Orbit"
        musicPause()

        if kind == .single {
            alerts.post(NotchAlert(symbol: "sparkles", tint: Tokens.live, title: "Focus done",
                                   subtitle: "\(minutes) minutes · \(dot): Nicely done.",
                                   actions: [.init(title: "OK", isPrimary: true)], sound: "Glass"))
            stopSession()
            return
        }

        if phase == .focus {
            if round >= rounds {
                alerts.post(NotchAlert(symbol: "sparkles", tint: Tokens.live, title: "Focus cycle complete",
                                       subtitle: "\(dot): \(rounds) rounds done. Well earned!",
                                       actions: [.init(title: "OK", isPrimary: true)], sound: "Glass"))
                stopSession()
                return
            }
            if automatic {
                alerts.post(NotchAlert(symbol: "cup.and.saucer.fill", tint: Tokens.attention, title: "Break time",
                                       subtitle: "\(dot): Good work. Take a \(breakMinutes)-minute break.",
                                       actions: [.init(title: "OK", isPrimary: true)], duration: 5, sound: "Glass"))
                startBreak()
            } else {
                stage = .breakReady
                remaining = Double(breakMinutes) * 60
                alerts.post(NotchAlert(symbol: "cup.and.saucer.fill", tint: Tokens.attention, title: "Time for a break",
                                       subtitle: "\(dot): Good work. Take a break.",
                                       actions: [.init(title: "Finish") { [weak self] in self?.stopSession() },
                                                 .init(title: "Start \(breakMinutes) min break", isPrimary: true) { [weak self] in self?.startBreak() }],
                                       duration: 20, sound: "Glass"))
            }
        } else {
            round += 1
            if automatic {
                alerts.post(NotchAlert(symbol: "timer", tint: Tokens.live, title: "Back to focus",
                                       subtitle: "Round \(round) of \(rounds) · \(dot): You've got this.",
                                       actions: [.init(title: "OK", isPrimary: true)], duration: 5, sound: "Glass"))
                startNextFocus()
            } else {
                stage = .focusReady
                phase = .focus
                remaining = total
                alerts.post(NotchAlert(symbol: "timer", tint: Tokens.live, title: "Break's over",
                                       subtitle: "Ready for round \(round) of \(rounds)?",
                                       actions: [.init(title: "Finish") { [weak self] in self?.stopSession() },
                                                 .init(title: "Start focus", isPrimary: true) { [weak self] in self?.startNextFocus() }],
                                       duration: 20, sound: "Glass"))
            }
        }
    }

    // MARK: Focus music (only during focus)

    private(set) var playlist: FocusPlaylist?
    var pauseMusicOnBreaks = UserDefaults.standard.object(forKey: "focus.pauseMusic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pauseMusicOnBreaks, forKey: "focus.pauseMusic") }
    }
    private var musicActive = false

    func setPlaylist(link: String) async -> String? {
        guard let parsed = FocusPlaylist.parse(link) else {
            return "Paste a Spotify playlist link, e.g. open.spotify.com/playlist/…"
        }
        var p = parsed
        p.name = await FocusPlaylist.fetchName(p.webURL) ?? "Spotify playlist"
        playlist = p
        UserDefaults.standard.set(try? JSONEncoder().encode(p), forKey: "focus.playlist")
        return nil
    }

    func removePlaylist() {
        playlist = nil
        UserDefaults.standard.removeObject(forKey: "focus.playlist")
    }

    private func musicStart() {
        guard let playlist, let music else { return }
        music.playSpotify(playlist.uri)
        musicActive = true
    }

    private func musicPause() {
        guard musicActive, pauseMusicOnBreaks else { return }
        music?.pauseSpotify()
    }

    private func musicResume() {
        guard musicActive, pauseMusicOnBreaks else { return }
        music?.resumeSpotify()
    }

    // MARK: Notch

    var runningCount: Int { (hasStarted ? 1 : 0) + timers.count }

    var peekView: AnyView? {
        if hasStarted {
            return AnyView(HStack(spacing: 6) {
                Circle().fill(stage == .paused ? Tokens.secondary : phase == .focus ? Tokens.live : Tokens.attention)
                    .frame(width: 8, height: 8)
                Text(Self.clock(remaining))
            })
        }
        guard let t = nextTimer else { return nil }
        return AnyView(HStack(spacing: 6) {
            Image(systemName: "timer").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.live)
            Text(Self.clock(t.remaining(at: now)))
        })
    }
    var peekPriority: Int { 2 }

    var peekChip: PeekChip? {
        switch stage {
        case .breakReady:
            return PeekChip(symbol: "cup.and.saucer.fill", text: "Time for a break", tint: Tokens.attention, priority: 5)
        case .focusReady:
            return PeekChip(symbol: "timer", text: "Ready for round \(round)", tint: Tokens.live, priority: 5)
        case .running, .paused:
            let label = stage == .paused ? "Paused" : phase == .focus ? "Focus" : "Break"
            return PeekChip(symbol: stage == .paused ? "pause.fill" : "brain.head.profile", text: "\(label) \(Self.clock(remaining))",
                            tint: stage == .paused ? Tokens.secondary : phase == .focus ? Tokens.live : Tokens.attention, priority: 5)
        case .idle:
            guard let t = nextTimer else { return nil }
            let more = timers.count > 1 ? " +\(timers.count - 1)" : ""
            return PeekChip(symbol: "timer", text: "\(t.label) \(Self.clock(t.remaining(at: now)))\(more)",
                            tint: t.isPaused ? Tokens.secondary : Tokens.live, priority: 4)
        }
    }

    var panel: AnyView { AnyView(FocusPanel(module: self)) }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Focus time as a ring of 60 small dots; the lit part is what's left. Breaks are orange.
struct DotRing: View {
    let module: FocusModule
    var diameter: CGFloat = 92
    var dots = 60

    var body: some View {
        let lit = Int(((module.stage == .idle ? 1 : module.fraction) * Double(dots)).rounded(.up))
        let color: Color = module.stage == .paused ? Tokens.secondary : module.phase == .rest ? Tokens.attention : .white
        let dot = max(2.5, diameter / 26)
        ZStack {
            ForEach(0..<dots, id: \.self) { i in
                let a = Double(i) / Double(dots) * 2 * .pi - .pi / 2
                Circle()
                    .fill(i < lit ? color : Color.white.opacity(0.12))
                    .frame(width: dot, height: dot)
                    .offset(x: cos(a) * (diameter / 2 - dot), y: sin(a) * (diameter / 2 - dot))
            }
            Text(FocusModule.clock(module.stage == .idle ? Double(module.cycleFocusMinutes) * 60 : module.remaining))
                .font(.system(size: diameter * 0.22, weight: .semibold).monospacedDigit())
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeInOut(duration: 0.3), value: lit)
    }
}

/// The Timer & Focus page.
struct FocusPanel: View {
    let module: FocusModule
    @State private var customMinutes = ""
    @State private var customLabel = ""
    @State private var showSettings = false

    var body: some View {
        // Snapshots can't draw scroll views, so preview mode shows the page without one.
        if ModuleRegistry.isPreview { content } else { ScrollView(.vertical, showsIndicators: false) { content } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            focusCard
            timersSection
        }
        .padding(.bottom, 8)
    }

    // MARK: Focus

    private var focusCard: some View {
        @Bindable var module = module
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(module.headline).font(.system(size: 17, weight: .bold))
                    HStack(spacing: 6) {
                        if [.breakReady, .focusReady].contains(module.stage) || (module.stage == .running && module.phase == .rest) {
                            CompanionView(size: 14, motion: module.stage == .breakReady ? .celebrate : .idle)
                        }
                        Text(module.detail).font(.system(size: 12.5)).foregroundStyle(Tokens.secondary)
                    }
                    HStack(spacing: 8) { controls }.padding(.top, 6)
                }
                Spacer()
                if module.stage != .breakReady { DotRing(module: module, diameter: 104) }
            }

            Button { withAnimation(.easeOut(duration: 0.2)) { showSettings.toggle() } } label: {
                HStack(spacing: 4) {
                    Text("Focus settings").font(.system(size: 11.5, weight: .semibold))
                    Image(systemName: showSettings ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Tokens.secondary)
            }
            .buttonStyle(.plain)

            if showSettings {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        stepper("Focus", $module.cycleFocusMinutes, 5...120, step: 5, unit: "min")
                        stepper("Break", $module.breakMinutes, 1...30, step: 1, unit: "min")
                        stepper("Rounds", $module.rounds, 1...8, step: 1, unit: "")
                        stepper("Single focus", $module.singleFocusMinutes, 10...180, step: 5, unit: "min")
                    }
                    HStack(spacing: 10) {
                        CardLabel("Cycles")
                        HStack(spacing: 0) {
                            seg("Automatic", module.automatic) { module.automatic = true }
                            seg("Manual", !module.automatic) { module.automatic = false }
                        }
                        .padding(3)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    FocusMusicRow(module: module)
                }
                .transition(.opacity)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder private var controls: some View {
        switch module.stage {
        case .idle:
            PillButton(title: "Start \(module.rounds) × \(module.cycleFocusMinutes) min") { module.startCycle() }
            PillButton(title: "Focus \(module.singleFocusMinutes) min", fill: Tokens.surface2) { module.startFocus() }
        case .running:
            PillButton(title: "Pause", fill: Tokens.surface2) { module.pause() }
            PillButton(title: "Stop", fill: Tokens.surface2) { module.stopSession() }
        case .paused:
            PillButton(title: "Resume") { module.resume() }
            PillButton(title: "Stop", fill: Tokens.surface2) { module.stopSession() }
        case .breakReady:
            PillButton(title: "Start \(module.breakMinutes) min break") { module.startBreak() }
            PillButton(title: "Finish", fill: Tokens.surface2) { module.stopSession() }
        case .focusReady:
            PillButton(title: "Start focus") { module.startNextFocus() }
            PillButton(title: "Finish", fill: Tokens.surface2) { module.stopSession() }
        }
    }

    // MARK: Timers

    private var timersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardLabel("Timers").padding(.leading, 4)
            ForEach(module.timers) { t in timerRow(t) }

            // Presets: click to start; right-click to remove.
            HStack(spacing: 8) {
                ForEach(module.timerPresets, id: \.self) { m in
                    Button { module.startTimer(m) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "timer").font(.system(size: 11, weight: .semibold))
                            Text("\(m) min").font(.system(size: 12.5, weight: .semibold))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Remove preset") { module.timerPresets.removeAll { $0 == m } } }
                }
                Spacer(minLength: 0)
            }

            // Custom timer
            HStack(spacing: 8) {
                TextField("Min", text: $customMinutes)
                    .textFieldStyle(.plain).font(.system(size: 12.5).monospacedDigit())
                    .frame(width: 44)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.surface2))
                    .onSubmit(startCustom)
                TextField("Name (optional)", text: $customLabel)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.surface2))
                    .onSubmit(startCustom)
                PillButton(title: "Start", action: startCustom)
                Button("Save as preset") {
                    if let m = Int(customMinutes), m > 0, !module.timerPresets.contains(m) {
                        module.timerPresets.append(m)
                        module.timerPresets.sort()
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                .disabled(Int(customMinutes) == nil)
            }
            Text("Run as many timers as you like. Right-click a preset to remove it.")
                .font(.system(size: 11)).foregroundStyle(Tokens.faint).padding(.leading, 4)
        }
    }

    private func timerRow(_ t: FocusModule.Countdown) -> some View {
        let left = t.remaining(at: module.now)
        return HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 3)
                Circle().trim(from: 0, to: t.total > 0 ? left / t.total : 0)
                    .stroke(t.isPaused ? Tokens.secondary : Tokens.live, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.label).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(t.isPaused ? "Paused" : "Ends \(t.endsAt.formatted(.dateTime.hour().minute()))")
                    .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
            }
            Spacer()
            Text(FocusModule.clock(left)).font(.system(size: 18, weight: .bold).monospacedDigit())
            IconButton(symbol: t.isPaused ? "play.fill" : "pause.fill", size: 11) { module.toggleTimer(t.id) }
            IconButton(symbol: "xmark", size: 10) { module.removeTimer(t.id) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func startCustom() {
        guard let m = Int(customMinutes.trimmingCharacters(in: .whitespaces)), m > 0 else { return }
        module.startTimer(m, label: customLabel)
        customMinutes = ""
        customLabel = ""
    }

    // MARK: Pieces

    private func stepper(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, step: Int, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CardLabel(title)
            HStack(spacing: 6) {
                IconButton(symbol: "minus", size: 9) { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) }
                Text("\(value.wrappedValue)\(unit.isEmpty ? "" : " \(unit)")").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 46)
                IconButton(symbol: "plus", size: 9) { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) }
            }
        }
    }

    private func seg(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? .white : Tokens.secondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(on ? Color.white.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// A Spotify playlist for focus sessions.
struct FocusPlaylist: Codable, Equatable {
    /// e.g. spotify:playlist:37i9dQZF1DX8Uebhn9wzrS
    var uri: String
    var webURL: URL
    var name: String = ""

    /// Accepts open.spotify.com links (playlist or album, with or without ?si=…) and spotify: URIs.
    static func parse(_ text: String) -> FocusPlaylist? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kinds = ["playlist", "album"]
        if t.hasPrefix("spotify:") {
            let parts = t.split(separator: ":").map(String.init)
            guard parts.count >= 3, let kindIndex = parts.firstIndex(where: kinds.contains), kindIndex + 1 < parts.count else { return nil }
            let kind = parts[kindIndex], id = parts[kindIndex + 1]
            return FocusPlaylist(uri: "spotify:\(kind):\(id)", webURL: URL(string: "https://open.spotify.com/\(kind)/\(id)")!)
        }
        guard let url = URL(string: t), url.host?.contains("spotify.com") == true else { return nil }
        let comps = url.pathComponents.filter { $0 != "/" }
        guard let i = comps.firstIndex(where: kinds.contains), i + 1 < comps.count else { return nil }
        let kind = comps[i], id = comps[i + 1]
        return FocusPlaylist(uri: "spotify:\(kind):\(id)", webURL: URL(string: "https://open.spotify.com/\(kind)/\(id)")!)
    }

    /// The playlist's name from Spotify's public oEmbed endpoint (no login needed).
    static func fetchName(_ url: URL) async -> String? {
        var c = URLComponents(string: "https://open.spotify.com/oembed")!
        c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let api = c.url, let (data, _) = try? await URLSession.shared.data(from: api),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["title"] as? String
    }
}

/// Focus tab row: which playlist plays during focus.
struct FocusMusicRow: View {
    let module: FocusModule
    @State private var editing = false
    @State private var link = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardLabel("Focus music · Spotify")
            if editing || module.playlist == nil && !link.isEmpty {
                HStack(spacing: 6) {
                    TextField("Paste a Spotify playlist link", text: $link)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.surface2))
                        .onSubmit(save)
                    PillButton(title: saving ? "…" : "Save", action: save)
                    Button("Cancel") { editing = false; link = ""; error = nil }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                }
                if let error { Text(error).font(.system(size: 10.5)).foregroundStyle(Tokens.error) }
            } else if let p = module.playlist {
                HStack(spacing: 6) {
                    Image(systemName: "music.note.list").font(.system(size: 11)).foregroundStyle(Tokens.live)
                    Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Menu {
                        Button("Change playlist…") { editing = true }
                        Toggle("Pause music on breaks", isOn: Binding(get: { module.pauseMusicOnBreaks },
                                                                      set: { module.pauseMusicOnBreaks = $0 }))
                        Divider()
                        Button("Remove playlist") { module.removePlaylist() }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            } else {
                Button { editing = true } label: {
                    Label("Choose a playlist to play when focus starts", systemImage: "plus.circle")
                        .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func save() {
        saving = true
        Task {
            error = await module.setPlaylist(link: link)
            saving = false
            if error == nil { editing = false; link = "" }
        }
    }
}
