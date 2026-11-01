import AppKit
import SwiftUI

/// Now playing from Spotify or Apple Music: play/pause, skip, shuffle, repeat, volume and scrubbing.
/// Uses AppleScript: macOS asks once for permission to control each player.
@MainActor
@Observable
final class MusicModule: NotchModule {
    let id = "music"
    let title = "Music"
    let symbol = "music.note"

    private(set) var track: Track?
    /// When `track` was read, so the position can keep moving between reads.
    private(set) var readAt = Date.now
    private(set) var artwork: NSImage?
    private var artworkKey = ""
    private var timer: Timer?
    /// After you change something, ignore stale reads for a moment so controls don't flicker back.
    private var holdUntil = Date.distantPast
    private let bridge = PlayerBridge()

    // MARK: Lifecycle

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        track = nil
    }

    private func refresh() {
        // Talking to Spotify/Music can show a permission prompt; onboarding asks first.
        guard Onboarding.allowsMusicPrompt else { return }
        Task {
            let next = await bridge.nowPlaying()
            guard Date.now >= holdUntil else { return }
            self.track = next
            self.readAt = .now
            await self.updateArtwork(for: next)
        }
    }

    private func updateArtwork(for track: Track?) async {
        guard let track else { artwork = nil; artworkKey = ""; return }
        let key = "\(track.player.rawValue)|\(track.title)|\(track.artist)"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil
        if let url = track.artworkURL {
            if let (data, _) = try? await URLSession.shared.data(from: url) { artwork = NSImage(data: data) }
        } else if let data = await bridge.musicArtwork() {
            artwork = NSImage(data: data)
        }
    }

    /// Position now, counting time since the last read while playing.
    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        let p = track.position + (track.isPlaying ? date.timeIntervalSince(readAt) : 0)
        return min(p, track.duration)
    }

    // MARK: Controls

    func send(_ command: PlayerBridge.Command) {
        guard var t = track else { return }
        // Update the UI right away; the player catches up.
        switch command {
        case .playPause: t.isPlaying.toggle(); t.position = position(at: .now)
        case .shuffle(let on): t.shuffle = on
        case .repeatMode(let mode): t.repeatMode = mode
        case .volume(let v): t.volume = v
        case .seek(let s): t.position = s
        case .next, .previous, .playURI, .pause, .resume: break
        }
        track = t
        readAt = .now
        holdUntil = .now.addingTimeInterval(1.2)
        let player = t.player
        Task {
            await bridge.send(command, to: player)
            try? await Task.sleep(for: .milliseconds(350))
            holdUntil = .distantPast
            refresh()
        }
    }

    // MARK: Used by Focus

    /// Starts a Spotify playlist (opens Spotify if it isn't running).
    func playSpotify(_ uri: String) { sendSpotify(.playURI(uri)) }
    func pauseSpotify() { sendSpotify(.pause) }
    func resumeSpotify() { sendSpotify(.resume) }

    private func sendSpotify(_ command: PlayerBridge.Command) {
        Task {
            await bridge.send(command, to: .spotify)
            try? await Task.sleep(for: .milliseconds(600))
            refresh()
        }
    }

    func toggleShuffle() { if let t = track { send(.shuffle(!t.shuffle)) } }

    /// Off → all → one (Apple Music only) → off.
    func cycleRepeat() {
        guard let t = track else { return }
        let next: Track.RepeatMode = switch t.repeatMode {
        case .off: .all
        case .all: t.player == .music ? .one : .off
        case .one: .off
        }
        send(.repeatMode(next))
    }

    func openPlayer() {
        guard let t = track else { return }
        let bundle = t.player == .spotify ? "com.spotify.client" : "com.apple.Music"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    // MARK: Views

    var peekView: AnyView? {
        guard let track else { return nil }
        return AnyView(HStack(spacing: 8) {
            ArtworkView(image: artwork, size: 28, radius: 7)
            // Play/pause right in the peek, without opening the panel.
            Button { self.send(.playPause) } label: {
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Waveform(active: track.isPlaying)
        })
    }
    var peekSide: PeekSide { .leading }

    var peekChip: PeekChip? {
        guard let t = track, t.isPlaying else { return nil }
        return PeekChip(symbol: "music.note", text: "\(t.title) · \(t.artist)", tint: Tokens.live, priority: 1)
    }

    var homeCard: AnyView? { AnyView(MusicCard(module: self)) }
    var panel: AnyView { AnyView(MusicPanel(module: self)) }
}

// MARK: - Model

struct Track: Equatable, Sendable {
    enum Player: String, Sendable { case spotify = "Spotify", music = "Music" }
    enum RepeatMode: String, Sendable { case off, all, one }

    var player: Player
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var artworkURL: URL?
    var shuffle: Bool
    var repeatMode: RepeatMode
    var volume: Int
}

/// Talks to the players with AppleScript on a background queue so the notch never stutters.
final class PlayerBridge: @unchecked Sendable {
    enum Command: Sendable, Equatable {
        case playPause, next, previous
        case shuffle(Bool), repeatMode(Track.RepeatMode), volume(Int), seek(Double)
        case playURI(String), pause, resume
    }

    private let queue = DispatchQueue(label: "orbit.music")

    private static let ids: [(Track.Player, String)] = [
        (.spotify, "com.spotify.client"), (.music, "com.apple.Music"),
    ]

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// The playing track, preferring whichever player is actually playing.
    func nowPlaying() async -> Track? {
        await withCheckedContinuation { cont in
            queue.async {
                var found: [Track] = []
                for (player, bundle) in Self.ids where Self.isRunning(bundle) {
                    if let t = Self.read(player) { found.append(t) }
                }
                cont.resume(returning: found.first(where: \.isPlaying) ?? found.first)
            }
        }
    }

    func send(_ command: Command, to player: Track.Player) async {
        let app = player.rawValue
        let line: String = switch command {
        case .playPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        case .volume(let v): "set sound volume to \(min(max(v, 0), 100))"
        case .seek(let s): "set player position to \(String(format: "%.1f", max(s, 0)))"
        case .playURI(let uri): "play track \"\(uri.replacingOccurrences(of: "\"", with: ""))\""
        case .pause: "pause"
        case .resume: "play"
        case .shuffle(let on): player == .spotify ? "set shuffling to \(on)" : "set shuffle enabled to \(on)"
        case .repeatMode(let mode):
            player == .spotify ? "set repeating to \(mode != .off)" : "set song repeat to \(mode.rawValue)"
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                _ = Self.run("tell application \"\(app)\" to \(line)")
                cont.resume()
            }
        }
    }

    /// Apple Music doesn't expose an artwork URL, so read the raw image data.
    func musicArtwork() async -> Data? {
        await withCheckedContinuation { cont in
            queue.async {
                guard Self.isRunning("com.apple.Music") else { return cont.resume(returning: nil) }
                let d = Self.run("tell application \"Music\" to get raw data of artwork 1 of current track")
                cont.resume(returning: d?.data)
            }
        }
    }

    private static let sep = "|~|"

    private static func read(_ player: Track.Player) -> Track? {
        let spotify = player == .spotify
        let durationExpr = spotify ? "((duration of t) / 1000)" : "(duration of t)"
        let artExpr = spotify ? "(artwork url of t)" : "\"\""
        let shuffleExpr = spotify ? "shuffling" : "shuffle enabled"
        let repeatExpr = spotify ? "(repeating as string)" : "(song repeat as string)"
        let script = """
        tell application "\(player.rawValue)"
            if player state is stopped then return ""
            set t to current track
            return (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)" & (player state as string) & "\(sep)" & (player position as string) & "\(sep)" & (\(durationExpr) as string) & "\(sep)" & \(artExpr) & "\(sep)" & (\(shuffleExpr) as string) & "\(sep)" & \(repeatExpr) & "\(sep)" & (sound volume as string)
        end tell
        """
        guard let out = run(script)?.stringValue, !out.isEmpty else { return nil }
        let p = out.components(separatedBy: sep)
        guard p.count >= 10 else { return nil }
        // Swedish and other locales write decimals with a comma.
        func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        let repeatMode: Track.RepeatMode = switch p[8] {
        case "true", "all": .all
        case "one": .one
        default: .off
        }
        return Track(player: player, title: p[0], artist: p[1], album: p[2],
                     isPlaying: p[3] == "playing", position: num(p[4]), duration: num(p[5]),
                     artworkURL: URL(string: p[6]).flatMap { $0.scheme == nil ? nil : $0 },
                     shuffle: p[7] == "true", repeatMode: repeatMode, volume: Int(num(p[9])))
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}

// MARK: - Views

/// Home card: artwork, title, progress and the main buttons.
struct MusicCard: View {
    let module: MusicModule

    var body: some View {
        NotchCard {
            if let track = module.track {
                VStack(alignment: .leading, spacing: 8) {
                    CardLabel("Now playing · \(track.player.rawValue)")
                    HStack(spacing: 10) {
                        RecordOrCover(image: module.artwork, spinning: track.isPlaying, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(track.artist).font(.system(size: 12)).foregroundStyle(Tokens.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    SeekBar(module: module, showTimes: false)
                    TransportControls(module: module, compact: true)
                }
            } else {
                EmptyMusic()
            }
        }
    }
}

/// Music tab: big record, scrubbing, shuffle/repeat, volume.
struct MusicPanel: View {
    let module: MusicModule
    @State private var showDevices = false

    var body: some View {
        NotchCard {
            if showDevices {
                SpotifyDevicesView { showDevices = false }
            } else if let track = module.track {
                HStack(spacing: 22) {
                    RecordOrCover(image: module.artwork, spinning: track.isPlaying, size: 150)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            CardLabel("Now playing · \(track.player.rawValue)")
                            Spacer()
                            Button("Open \(track.player.rawValue)") { module.openPlayer() }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                            Text("\(track.artist) — \(track.album)").font(.system(size: 12.5))
                                .foregroundStyle(Tokens.secondary).lineLimit(1)
                        }
                        SeekBar(module: module, showTimes: true)
                        TransportControls(module: module, compact: false)
                        HStack(spacing: 10) {
                            VolumeControl(module: module, volume: track.volume)
                            if track.player == .spotify {
                                SpotifyDeviceButton(trackKey: track.title + track.artist) { showDevices = true }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyMusic()
            }
        }
    }
}

struct EmptyMusic: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardLabel("Music")
            Spacer(minLength: 0)
            Image(systemName: "music.note").font(.system(size: 20)).foregroundStyle(Tokens.faint)
            Text("Play something in Spotify or Music").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
        }
    }
}

struct TransportControls: View {
    let module: MusicModule
    let compact: Bool

    var body: some View {
        if let t = module.track {
            HStack(spacing: compact ? 0 : 14) {
                if !compact {
                    ToggleIcon(symbol: "shuffle", on: t.shuffle, help: "Shuffle") { module.toggleShuffle() }
                }
                IconButton(symbol: "backward.fill") { module.send(.previous) }
                if compact { Spacer() }
                IconButton(symbol: t.isPlaying ? "pause.fill" : "play.fill", size: compact ? 13 : 17) { module.send(.playPause) }
                if compact { Spacer() }
                IconButton(symbol: "forward.fill") { module.send(.next) }
                if !compact {
                    ToggleIcon(symbol: t.repeatMode == .one ? "repeat.1" : "repeat", on: t.repeatMode != .off,
                               help: "Repeat") { module.cycleRepeat() }
                }
            }
            .frame(maxWidth: compact ? .infinity : nil)
        }
    }
}

/// Icon that lights up green when on (shuffle, repeat).
struct ToggleIcon: View {
    let symbol: String
    let on: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Tokens.live : Tokens.secondary)
                .frame(width: 28, height: 28)
                .overlay(alignment: .bottom) {
                    if on { Circle().fill(Tokens.live).frame(width: 3, height: 3).offset(y: -2) }
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Progress bar you can click or drag to jump in the song.
struct SeekBar: View {
    let module: MusicModule
    let showTimes: Bool
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = module.track?.duration ?? 0
            let pos = module.position(at: context.date)
            let fraction = dragFraction ?? (duration > 0 ? pos / duration : 0)
            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokens.surface2)
                        Capsule().fill(.white).frame(width: geo.size.width * fraction)
                        if dragFraction != nil {
                            Circle().fill(.white).frame(width: 9, height: 9)
                                .offset(x: geo.size.width * fraction - 4.5)
                        }
                    }
                    .frame(height: dragFraction == nil ? 3 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragFraction = min(max(v.location.x / geo.size.width, 0), 1) }
                        .onEnded { _ in
                            if let f = dragFraction, duration > 0 { module.send(.seek(f * duration)) }
                            dragFraction = nil
                        })
                }
                .frame(height: 12)
                if showTimes {
                    HStack {
                        Text(Self.time((dragFraction.map { $0 * duration }) ?? pos))
                        Spacer()
                        Text("-" + Self.time(max(duration - ((dragFraction.map { $0 * duration }) ?? pos), 0)))
                    }
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Tokens.faint)
                }
            }
        }
    }

    static func time(_ s: Double) -> String {
        let s = Int(s.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct VolumeControl: View {
    let module: MusicModule
    let volume: Int
    @State private var dragValue: Double?

    var body: some View {
        let value = dragValue ?? Double(volume) / 100
        HStack(spacing: 8) {
            Button { module.send(.volume(volume > 0 ? 0 : 50)) } label: {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.fill").font(.system(size: 10))
                    .foregroundStyle(Tokens.secondary).frame(width: 14)
            }
            .buttonStyle(.plain)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tokens.surface2)
                    Capsule().fill(Tokens.secondary).frame(width: geo.size.width * value)
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in dragValue = min(max(v.location.x / geo.size.width, 0), 1) }
                    .onEnded { _ in
                        if let d = dragValue { module.send(.volume(Int((d * 100).rounded()))) }
                        dragValue = nil
                    })
            }
            .frame(height: 12)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(Tokens.secondary)
        }
        .frame(maxWidth: 220)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                AngularGradient(colors: [.orange, .yellow, .purple, .teal, .orange], center: .center)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Album art as a record label, on a black grooved disc that spins while playing.
struct VinylView: View {
    let image: NSImage?
    let spinning: Bool
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 360
            ZStack {
                Circle().fill(Color(white: 0.07))
                ForEach(1..<6) { i in
                    Circle().stroke(Color.white.opacity(0.05), lineWidth: 1)
                        .padding(CGFloat(i) * size * 0.05)
                }
                ArtworkView(image: image, size: size * 0.46, radius: size)
                Circle().fill(.black).frame(width: size * 0.06)
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? angle : 0))
        }
    }
}

struct Waveform: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4) { i in
                    Capsule().fill(Tokens.secondary)
                        .frame(width: 3, height: active ? 4 + 10 * abs(sin(t * 4 + Double(i) * 1.3)) : 4)
                }
            }
            .frame(height: 14)
        }
    }
}

struct ProgressBar: View {
    let value: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.surface2)
                Capsule().fill(tint).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 3)
    }
}

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering ? Tokens.surface2 : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Vinyl or plain cover art, per Settings → Appearance.
struct RecordOrCover: View {
    let image: NSImage?
    let spinning: Bool
    let size: CGFloat

    var body: some View {
        if Appearance.shared.musicStyle == .vinyl {
            VinylView(image: image, spinning: spinning, size: size)
        } else {
            ArtworkView(image: image, size: size, radius: size * 0.14)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
        }
    }
}
