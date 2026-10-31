import AppKit
import AVFoundation
import CoreAudio
import SwiftUI

/// Call controls and mic safety: shows when an app is using the mic, mutes/unmutes the default
/// input device system-wide, and mutes it on its own after a stretch of silence.
@MainActor
@Observable
final class MicModule: NotchModule {
    let id = "mic"
    let title = "Mic"
    let symbol = "mic"

    static let safetyChoices = [0, 2, 5, 10]
    /// Below this the room counts as silent.
    static let silenceDB: Float = -50

    // MARK: State

    private(set) var deviceName: String?
    /// Another app is recording from the default input.
    private(set) var inUse = false
    private(set) var isMuted = false
    /// The device has a mute switch or an input volume we can use.
    private(set) var canMute = false
    /// The call app that most likely has the mic, e.g. "Zoom".
    private(set) var callApp: String?
    /// Latest input level in dB (about -160…0). Only live while the meter runs.
    private(set) var level: Float = -160
    private(set) var meterRunning = false
    private(set) var permission = AVCaptureDevice.authorizationStatus(for: .audio)
    /// When the mic last heard something; the safety timer counts from here.
    private(set) var silentSince: Date?

    /// Minutes of silence before the mic is paused; 0 turns mic safety off.
    var safetyMinutes: Int = UserDefaults.standard.object(forKey: "mic.safetyMinutes") as? Int ?? 5 {
        didSet {
            UserDefaults.standard.set(safetyMinutes, forKey: "mic.safetyMinutes")
            silentSince = meterRunning ? .now : nil
            tick()
        }
    }

    private let alerts: AlertCenter
    private let meter = MicLevelMeter()
    private var timer: Timer?
    private var device: AudioDeviceID?
    /// Orbit muted the mic (button, hotkey or safety); undone when the call ends.
    private var mutedByViktor = false
    private var lastLevelAt: Date?
    private var askedPermission = false

    /// Input volume to restore when the device has no mute switch and we muted via volume.
    private var savedVolume: Float? {
        get { UserDefaults.standard.object(forKey: "mic.savedVolume") as? Float }
        set { UserDefaults.standard.set(newValue, forKey: "mic.savedVolume") }
    }

    init(alerts: AlertCenter) {
        self.alerts = alerts
    }

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopMeter()
    }

    // MARK: Controls

    /// Mute or unmute the default input device. Safe to call from a global hotkey.
    func toggleMute() { setMuted(!isMuted) }

    func setMuted(_ muted: Bool) {
        guard let device = device ?? MicHardware.defaultInputDevice() else { return }
        var ok = false
        if MicHardware.supportsMute(device) {
            ok = MicHardware.setMuted(device, muted)
        } else if MicHardware.supportsVolume(device) {
            if muted {
                if let v = MicHardware.inputVolume(device), v > 0.001 { savedVolume = v }
                ok = MicHardware.setInputVolume(device, 0)
            } else {
                ok = MicHardware.setInputVolume(device, savedVolume ?? 0.75)
                savedVolume = nil
            }
        }
        guard ok else { return }
        mutedByViktor = muted
        isMuted = muted
        if muted { stopMeter() } else { silentSince = nil }
        tick()
    }

    func requestPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            askedPermission = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.permission = AVCaptureDevice.authorizationStatus(for: .audio)
                    self?.tick()
                }
            }
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        default: break
        }
    }

    /// Seconds left before mic safety pauses the mic, while it's counting.
    var safetyRemaining: TimeInterval? {
        guard meterRunning, safetyMinutes > 0, let silentSince else { return nil }
        return max(0, Double(safetyMinutes * 60) - Date.now.timeIntervalSince(silentSince))
    }

    // MARK: Polling

    private func tick() {
        let current = MicHardware.defaultInputDevice()
        if current != device {
            stopMeter()
            device = current
            deviceName = current.flatMap(MicHardware.name)
        }
        guard let device else {
            inUse = false; isMuted = false; canMute = false; callApp = nil
            return
        }
        canMute = MicHardware.supportsMute(device) || MicHardware.supportsVolume(device)
        isMuted = MicHardware.isMuted(device) ?? ((MicHardware.inputVolume(device) ?? 1) <= 0.001 && savedVolume != nil)
        if !isMuted { mutedByViktor = false }

        // Who's recording. On 14.2+ CoreAudio lists processes, so our own meter doesn't count.
        let wasInUse = inUse
        if let others = MicHardware.otherProcessesRecording() {
            inUse = !others.isEmpty
            callApp = inUse ? Self.callApp(among: others.compactMap(\.bundleID)) ?? Self.appName(others) ?? Self.runningCallApp() : nil
        } else {
            // Older macOS: the device-wide flag also sees our own meter, so while it runs we
            // trust "a call app is still open" instead.
            let running = Self.runningCallApp()
            inUse = meterRunning ? running != nil : MicHardware.isRunningSomewhere(device)
            callApp = inUse ? running : nil
        }

        // The call is over: undo our mute so the next call doesn't start silently muted.
        if wasInUse, !inUse, mutedByViktor {
            setMutedQuietly(device, false)
        }

        permission = AVCaptureDevice.authorizationStatus(for: .audio)
        let wantsMeter = inUse && !isMuted && safetyMinutes > 0
            && (MicHardware.otherProcessesRecording() != nil || callApp != nil)
        if wantsMeter, permission == .notDetermined, !askedPermission { requestPermission() }
        if wantsMeter, permission == .authorized { startMeter() } else { stopMeter() }

        checkSilence()
    }

    private func setMutedQuietly(_ device: AudioDeviceID, _ muted: Bool) {
        if MicHardware.supportsMute(device) {
            MicHardware.setMuted(device, muted)
        } else if !muted, let v = savedVolume {
            MicHardware.setInputVolume(device, v)
            savedVolume = nil
        }
        mutedByViktor = muted
        isMuted = muted
    }

    // MARK: Level meter & mic safety

    private func startMeter() {
        guard !meterRunning else { return }
        let ok = meter.start { [weak self] db in self?.receive(db) }
        meterRunning = ok
        silentSince = ok ? .now : nil
        lastLevelAt = nil
    }

    private func stopMeter() {
        guard meterRunning else { return }
        meter.stop()
        meterRunning = false
        level = -160
        silentSince = nil
        lastLevelAt = nil
    }

    private func receive(_ db: Float) {
        guard meterRunning else { return }
        level = db
        lastLevelAt = .now
        if db > Self.silenceDB { silentSince = .now }
    }

    private func checkSilence() {
        guard meterRunning, safetyMinutes > 0, let silentSince, let lastLevelAt,
              Date.now.timeIntervalSince(lastLevelAt) < 3,
              Date.now.timeIntervalSince(silentSince) >= Double(safetyMinutes * 60) else { return }
        let minutes = safetyMinutes
        setMuted(true)
        guard isMuted else { return }
        alerts.post(NotchAlert(
            symbol: "mic.slash.fill", tint: Tokens.attention,
            title: "Mic paused after \(minutes) min of silence",
            subtitle: callApp.map { "Muted for \($0) and every other app" } ?? "Your mic is muted for every app",
            actions: [
                .init(title: "Unmute", isPrimary: true, perform: { [weak self] in self?.setMuted(false) }),
                .init(title: "Keep muted"),
            ],
            duration: 20, sound: "Tink"))
    }

    // MARK: Call apps

    private static let callApps: [(bundle: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Teams"),
        ("com.microsoft.teams", "Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.apple.avconferenced", "FaceTime"),
    ]

    /// Matches helper processes too, e.g. "us.zoom.xos.helper" → Zoom.
    private static func callApp(among bundleIDs: [String]) -> String? {
        for app in callApps where bundleIDs.contains(where: { $0 == app.bundle || $0.hasPrefix(app.bundle + ".") }) {
            return app.name
        }
        return nil
    }

    private static func appName(_ processes: [MicHardware.InputProcess]) -> String? {
        for p in processes {
            if let app = NSRunningApplication(processIdentifier: p.pid), app.activationPolicy == .regular,
               let name = app.localizedName { return name }
        }
        return nil
    }

    private static func runningCallApp() -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return callApps.first { running.contains($0.bundle) }?.name
    }

    // MARK: Views

    var peekChip: PeekChip? {
        guard inUse else { return nil }
        return PeekChip(symbol: isMuted ? "mic.slash.fill" : "mic.fill",
                        text: isMuted ? "Mic muted" : "Mic live",
                        tint: isMuted ? Tokens.secondary : Tokens.error, priority: 5)
    }

    var panel: AnyView { AnyView(MicPanel(module: self)) }
}

// MARK: - Panel

struct MicPanel: View {
    let module: MicModule

    var body: some View {
        HStack(spacing: 10) {
            NotchCard {
                VStack(spacing: 10) {
                    CardLabel(module.callApp ?? "Microphone").frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    MuteButton(module: module)
                    Text(status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(module.inUse && !module.isMuted ? Tokens.error : Tokens.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: 210)

            NotchCard {
                VStack(alignment: .leading, spacing: 10) {
                    CardLabel("Input level")
                    LevelDots(level: module.level, active: module.meterRunning)
                    Text(module.deviceName ?? "No microphone")
                        .font(.system(size: 11)).foregroundStyle(Tokens.faint).lineLimit(1)

                    CardLabel("Mic safety · pause after silence")
                    HStack(spacing: 6) {
                        ForEach(MicModule.safetyChoices, id: \.self) { m in
                            Button(m == 0 ? "Off" : "\(m) min") { module.safetyMinutes = m }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(module.safetyMinutes == m ? Color.white : Tokens.surface2))
                                .foregroundStyle(module.safetyMinutes == m ? Color.black : Tokens.secondary)
                        }
                    }
                    footnote
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var status: String {
        guard module.canMute || module.deviceName == nil else { return "This mic can't be muted" }
        if !module.inUse { return module.isMuted ? "Muted · not in use" : "Not in use" }
        return module.isMuted ? "Muted" : "Live" + (module.callApp.map { " in \($0)" } ?? "")
    }

    @ViewBuilder private var footnote: some View {
        if module.safetyMinutes > 0, module.permission == .denied || module.permission == .restricted {
            Button(action: module.requestPermission) {
                Label("Mic safety needs microphone access. Open Settings…", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Tokens.attention)
            }
            .buttonStyle(.plain)
        } else if module.safetyMinutes > 0, module.permission == .notDetermined {
            Button(action: module.requestPermission) {
                Label("Allow microphone access for mic safety", systemImage: "mic.badge.plus")
                    .font(.system(size: 11)).foregroundStyle(Tokens.secondary)
            }
            .buttonStyle(.plain)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(safetyText).font(.system(size: 11)).foregroundStyle(Tokens.faint).lineLimit(1)
            }
        }
    }

    private var safetyText: String {
        if module.safetyMinutes == 0 { return "Off. The mic stays live until you mute it." }
        if let left = module.safetyRemaining {
            let s = Int(left.rounded(.up))
            return "Quiet for a while? Muting in \(String(format: "%d:%02d", s / 60, s % 60))."
        }
        if module.isMuted { return "Paused while the mic is muted." }
        return "Listens only while another app uses the mic."
    }
}

/// The big round mute switch.
struct MuteButton: View {
    let module: MicModule
    @State private var hovering = false

    var body: some View {
        let live = !module.isMuted
        Button(action: module.toggleMute) {
            Image(systemName: live ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(live ? Color.black : Color.white)
                .frame(width: 76, height: 76)
                .background(Circle().fill(live ? (module.inUse ? Tokens.error : Color.white) : Tokens.surface2))
                .overlay(Circle().stroke(Tokens.stroke))
                .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!module.canMute)
        .opacity(module.canMute ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(Tokens.spring, value: module.isMuted)
        .animation(Tokens.spring, value: hovering)
        .help(live ? "Mute the mic for every app" : "Unmute the mic")
    }
}

/// A row of dots lit by the input level (-60 dB…0 dB).
struct LevelDots: View {
    let level: Float
    let active: Bool
    var count = 18

    var body: some View {
        let fraction = Double(min(max((level + 60) / 60, 0), 1))
        let lit = active ? Int((fraction * Double(count)).rounded()) : 0
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i < lit ? color(i) : Tokens.surface2)
                    .frame(width: 8, height: 8)
            }
        }
        .animation(.easeOut(duration: 0.12), value: lit)
    }

    private func color(_ i: Int) -> Color {
        let f = Double(i) / Double(count)
        return f > 0.85 ? Tokens.error : f > 0.65 ? Tokens.attention : Tokens.live
    }
}
