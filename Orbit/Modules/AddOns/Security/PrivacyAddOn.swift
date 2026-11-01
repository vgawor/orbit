import CoreAudio
import CoreMediaIO
import Foundation
import SwiftUI

// MARK: - Logic

extension SecurityKit {
    /// Whether any camera or microphone is being used by any app. These properties don't need
    /// camera or microphone permission, so no prompt appears.
    enum DeviceUse {
        struct Reading: Equatable, Sendable {
            var camera: Bool
            var mic: Bool
        }

        static func read() -> Reading { Reading(camera: cameraInUse(), mic: micInUse()) }

        static func cameraInUse() -> Bool {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var size: UInt32 = 0
            guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0,
                  size > 0 else { return false }
            var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
            var used: UInt32 = 0
            guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == 0
            else { return false }
            var running = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            for device in devices.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size) {
                var value: UInt32 = 0
                var got: UInt32 = 0
                if CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &value) == 0,
                   value != 0 { return true }
            }
            return false
        }

        static func micInUse() -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
                  size > 0 else { return false }
            var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
            else { return false }
            for device in devices where hasInput(device) {
                var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
                var value: UInt32 = 0
                var len = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(device, &running, 0, nil, &len, &value) == noErr, value != 0 { return true }
            }
            return false
        }

        private static func hasInput(_ device: AudioDeviceID) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
        }
    }

    /// One stretch of the camera or mic being on. Times are seconds since 1970.
    struct DeviceSession: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case camera, mic }
        var id: String { "\(kind.rawValue)-\(start)" }
        var kind: Kind
        var start: Double
        var end: Double?
    }

    enum DeviceLog {
        /// Opens or closes sessions to match the latest reading.
        static func apply(_ reading: DeviceUse.Reading, to log: [DeviceSession], at now: Double) -> [DeviceSession] {
            var log = log
            for (kind, on) in [(DeviceSession.Kind.camera, reading.camera), (.mic, reading.mic)] {
                let open = log.lastIndex { $0.kind == kind && $0.end == nil }
                if on, open == nil { log.append(DeviceSession(kind: kind, start: now)) }
                if !on, let i = open { log[i].end = now }
            }
            return log
        }

        /// Keeps only sessions that touch the day `now` falls in.
        static func today(_ log: [DeviceSession], now: Date, calendar: Calendar = .current) -> [DeviceSession] {
            let start = calendar.startOfDay(for: now).timeIntervalSince1970
            return log.filter { ($0.end ?? .infinity) >= start }
        }
    }
}

// MARK: - Module

/// Shows when any app uses the camera or microphone, with today's log.
@MainActor
@Observable
final class PrivacyAddOn: AddOnModule {
    let id = "addon.privacy"
    let title = "Camera & mic"
    let symbol = "video.badge.waveform"
    let addOn = AddOnInfo(category: .security, tier: .free,
                          summary: "See when any app turns on your camera or microphone, with today's log.")

    private static let file = "addon-privacy"
    private(set) var reading = SecurityKit.DeviceUse.Reading(camera: false, mic: false)
    private(set) var log: [SecurityKit.DeviceSession] = []
    private var timer: Timer?
    private var polling = false
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview {
            let day = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
            log = [
                .init(kind: .mic, start: day + 9 * 3600 + 2 * 60, end: day + 9 * 3600 + 31 * 60),
                .init(kind: .camera, start: day + 9 * 3600 + 2 * 60, end: day + 9 * 3600 + 30 * 60),
                .init(kind: .mic, start: day + 13 * 3600 + 15 * 60, end: day + 13 * 3600 + 18 * 60),
                .init(kind: .camera, start: day + 15 * 3600, end: day + 15 * 3600 + 45 * 60),
                .init(kind: .mic, start: day + 15 * 3600, end: nil),
            ]
            // Mic only, so other snapshots don't all say "Your camera is on".
            reading = .init(camera: false, mic: true)
        } else {
            log = SecurityKit.DeviceLog.today(Storage.load([SecurityKit.DeviceSession].self, from: Self.file) ?? [], now: .now)
        }
    }

    func start() {
        poll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // Close anything still open, so the log doesn't claim it stayed on.
        apply(.init(camera: false, mic: false))
    }

    private func poll() {
        guard !polling else { return }
        polling = true
        Task {
            let r = await Task.detached(priority: .utility) { SecurityKit.DeviceUse.read() }.value
            polling = false
            apply(r)
        }
    }

    private func apply(_ r: SecurityKit.DeviceUse.Reading) {
        let before = log
        reading = r
        log = SecurityKit.DeviceLog.today(SecurityKit.DeviceLog.apply(r, to: log, at: Date.now.timeIntervalSince1970), now: .now)
        if log != before, !ModuleRegistry.isPreview { Storage.save(log, to: Self.file) }
    }

    /// When the current camera session began.
    var cameraSince: Date? {
        guard reading.camera, let s = log.last(where: { $0.kind == .camera && $0.end == nil }) else { return nil }
        return Date(timeIntervalSince1970: s.start)
    }

    var peekChip: PeekChip? {
        if reading.camera { return PeekChip(symbol: "video.fill", text: "Camera on", tint: Tokens.live, priority: 3) }
        if reading.mic { return PeekChip(symbol: "mic.fill", text: "Mic on", tint: Tokens.attention, priority: 2) }
        return nil
    }

    var attention: Attention? {
        guard reading.camera else { return nil }
        let key = cameraSince.map { Int($0.timeIntervalSince1970) } ?? 0
        return Attention(id: "addon.privacy.camera-\(key)", symbol: "video.fill", tint: Tokens.live,
                         label: "Camera on", priority: 1, headline: "Your camera is on")
    }

    /// "Camera on", "Mic in use", "Camera and mic on" or "Camera and mic off".
    static func headline(_ r: SecurityKit.DeviceUse.Reading) -> String {
        switch (r.camera, r.mic) {
        case (true, true): "Camera and mic on"
        case (true, false): "Camera on"
        case (false, true): "Mic in use"
        case (false, false): "Camera and mic off"
        }
    }

    var homeCard: AnyView? { AnyView(SecPrivacyHomeCard(module: self) { [ctx, id] in ctx.openPanel(id) }) }

    var panel: AnyView { AnyView(SecPrivacyPanel(module: self)) }
}

/// Home: whether anything is using the camera or mic right now, and how often today.
struct SecPrivacyHomeCard: View {
    let module: PrivacyAddOn
    let open: () -> Void

    var body: some View {
        let r = module.reading
        let n = module.log.count
        DevSecHomeCard(label: "Camera & mic",
                       title: PrivacyAddOn.headline(r),
                       detail: n == 0 ? "Nothing used them today" : "Used \(n) time\(n == 1 ? "" : "s") today",
                       titleTint: r.camera ? Tokens.live : (r.mic ? Tokens.attention : .white),
                       open: open) {
            SecOnAirOrbit(size: 50, camera: r.camera, mic: r.mic, sign: false)
        }
    }
}

// MARK: - View

struct SecPrivacyPanel: View {
    let module: PrivacyAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: "video.badge.waveform", title: "Camera & mic",
                        subtitle: "Checks every 2 s whether any app is using them", tint: SecurityAddOns.tint)
            HStack(spacing: 12) {
                tile(on: module.reading.camera, symbol: "video.fill", name: "Camera", tint: Tokens.live)
                tile(on: module.reading.mic, symbol: "mic.fill", name: "Microphone", tint: Tokens.attention)
                // Orbit sits up under the "on air" light while anything listens or watches, and naps when nothing does.
                SecOnAirOrbit(size: 84, camera: module.reading.camera, mic: module.reading.mic)
                    .frame(width: 104, height: 104)
                    .glassCard(22)
            }
            .frame(height: 104)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardLabel("Today")
                    Spacer()
                    Text("\(module.log.count) time\(module.log.count == 1 ? "" : "s")")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.faint)
                }
                if module.log.isEmpty {
                    Text("Nothing has used your camera or microphone today.")
                        .font(.system(size: 12.5)).foregroundStyle(Tokens.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    NotchScroll {
                        VStack(spacing: 2) {
                            ForEach(module.log.reversed()) { SecSessionRow(session: $0) }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassCard(22)
        }
    }

    private func tile(on: Bool, symbol: String, name: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .foregroundStyle(on ? .black : Tokens.secondary)
                .frame(width: 46, height: 46)
                .background(Circle().fill(on ? tint : Tokens.surface))
                .shadow(color: on ? tint.opacity(0.5) : .clear, radius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                Text(on ? "In use" : "Off").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(on ? tint : .white)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(22)
    }
}

struct SecSessionRow: View {
    let session: SecurityKit.DeviceSession

    var body: some View {
        let start = Date(timeIntervalSince1970: session.start)
        HStack(spacing: 10) {
            Image(systemName: session.kind == .camera ? "video.fill" : "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(session.kind == .camera ? "Camera" : "Microphone").font(.system(size: 12.5)).frame(width: 90, alignment: .leading)
            Text(times(start)).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Tokens.secondary)
            Spacer()
            if session.end == nil {
                Text("On now").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.2))).foregroundStyle(tint)
            } else if let end = session.end {
                Text(duration(end - session.start)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Tokens.faint)
            }
        }
        .padding(.vertical, 4)
    }

    private var tint: Color { session.kind == .camera ? Tokens.live : Tokens.attention }

    private func times(_ start: Date) -> String {
        let s = start.formatted(date: .omitted, time: .shortened)
        guard let end = session.end else { return "\(s) – now" }
        return "\(s) – \(Date(timeIntervalSince1970: end).formatted(date: .omitted, time: .shortened))"
    }

    private func duration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return "\(max(1, Int(seconds))) s" }
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(m % 60) min"
    }
}
