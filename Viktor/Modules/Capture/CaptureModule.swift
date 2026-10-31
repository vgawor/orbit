import AppKit
import SwiftUI

/// Screenshots (area, window, screen, scrolling), drawing on screen and screen recording.
/// Everything is saved where macOS saves screenshots, and put on the Shelf.
@MainActor
@Observable
final class CaptureModule: NotchModule {
    let id = "capture"
    let title = "Capture"
    let symbol = "camera.viewfinder"

    enum Kind { case area, window, screen }

    /// Record the microphone with screen recordings.
    var voice = UserDefaults.standard.bool(forKey: "capture.voice") {
        didSet { UserDefaults.standard.set(voice, forKey: "capture.voice") }
    }
    /// Orbit isn't allowed to read the screen yet.
    private(set) var needsPermission = false
    /// A short problem message under the tiles, e.g. "Recording needs macOS 15".
    private(set) var message: String?
    private(set) var isScrolling = false
    private(set) var recordingStarted: Date?
    private(set) var isStopping = false
    private(set) var now = Date.now

    var isRecording: Bool { recordingStarted != nil }
    var runningCount: Int { isRecording ? 1 : 0 }
    var recordingElapsed: TimeInterval { recordingStarted.map { max(0, now.timeIntervalSince($0)) } ?? 0 }

    @ObservationIgnored private let shelf: ShelfModule
    @ObservationIgnored private let alerts: AlertCenter
    @ObservationIgnored private let startDrawing: @MainActor () -> Void
    @ObservationIgnored private let closePanel: @MainActor () -> Void
    @ObservationIgnored private var scrolling: ScrollingCapture?
    @ObservationIgnored private let picker = RecordingPicker()
    @ObservationIgnored private var recorder: AnyObject?
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    init(shelf: ShelfModule, alerts: AlertCenter,
         startDrawing: @escaping @MainActor () -> Void,
         closePanel: @escaping @MainActor () -> Void) {
        self.shelf = shelf
        self.alerts = alerts
        self.startDrawing = startDrawing
        self.closePanel = closePanel
    }

    func stop() {
        scrolling?.cancel()
        if isRecording { stopRecording() }
    }

    // MARK: Permission

    /// Returns true when capturing may go ahead; otherwise asks macOS and shows the Settings button.
    private func checkPermission() -> Bool {
        if CaptureFiles.hasScreenPermission { needsPermission = false; return true }
        CGRequestScreenCaptureAccess()
        needsPermission = true
        return false
    }

    func openSettings() { CaptureFiles.openScreenRecordingSettings() }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    // MARK: Screenshots

    func screenshot(_ kind: Kind) {
        guard checkPermission() else { return }
        closePanel()
        let url = CaptureFiles.newURL(ext: "png")
        let args: [String] = switch kind {
        case .area: ["-i", url.path]
        case .window: ["-i", "-W", url.path]
        case .screen: ["-m", url.path]
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300)) // let the notch close first
            _ = await CaptureFiles.screencapture(args)
            // Esc in interactive mode leaves no file: nothing to do.
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            delivered(url, title: "Screenshot saved")
        }
    }

    func scrollingScreenshot() {
        guard !isScrolling, checkPermission() else { return }
        closePanel()
        isScrolling = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            let session = ScrollingCapture { [weak self] outcome in self?.scrollingDone(outcome) }
            scrolling = session
            session.begin()
        }
    }

    private func scrollingDone(_ outcome: ScrollingCapture.Outcome) {
        scrolling = nil
        isScrolling = false
        switch outcome {
        case .saved(let url): delivered(url, title: "Scrolling screenshot saved")
        case .cancelled: break
        case .noPermission: needsPermission = true; postPermissionAlert()
        case .failed(let why): show("Scrolling screenshot failed: \(why)")
        }
    }

    func draw() {
        closePanel()
        startDrawing()
    }

    // MARK: Recording

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    func startRecording() {
        guard !isRecording else { return }
        guard #available(macOS 15.0, *) else { show("Recording needs macOS 15"); return }
        guard checkPermission() else { return }
        closePanel()
        picker.present { [weak self] result in
            guard let self, let result else { return }
            switch result {
            case .success(let box): self.beginRecording(box)
            case .failure(let error): self.recordingFailed(error)
            }
        }
    }

    @available(macOS 15.0, *)
    private func beginRecording(_ box: FilterBox) {
        let url = CaptureFiles.newURL("Orbit Recording", ext: "mov")
        let recorder = ScreenRecorder(filter: box.filter, microphone: voice, url: url) { [weak self] result in
            Task { @MainActor in self?.recordingFinished(result) }
        }
        self.recorder = recorder
        recorder.start { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.recorder = nil; self.recordingFailed(error); return }
                self.recordingStarted = .now
                self.now = .now
                self.clock?.invalidate()
                self.clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.now = .now }
                }
            }
        }
    }

    func stopRecording() {
        guard #available(macOS 15.0, *), let recorder = recorder as? ScreenRecorder, !isStopping else { return }
        isStopping = true
        recorder.stop()
    }

    private func recordingFinished(_ result: Result<URL, Error>) {
        clock?.invalidate(); clock = nil
        recorder = nil
        recordingStarted = nil
        isStopping = false
        switch result {
        case .success(let url) where FileManager.default.fileExists(atPath: url.path):
            delivered(url, title: "Recording saved", symbol: "record.circle")
        case .success: show("The recording couldn't be saved")
        case .failure(let error): recordingFailed(error)
        }
    }

    private func recordingFailed(_ error: Error) {
        if CaptureFiles.isPermissionError(error) {
            needsPermission = true
            postPermissionAlert()
        } else {
            show("Recording failed: \(error.localizedDescription)")
        }
    }

    // MARK: Results

    private func delivered(_ url: URL, title: String, symbol: String = "camera.viewfinder") {
        shelf.add([url])
        alerts.post(NotchAlert(symbol: symbol, tint: Tokens.live, title: title, subtitle: "On the Shelf",
                               actions: [.init(title: "Show in Finder") {
                                   NSWorkspace.shared.activateFileViewerSelecting([url])
                               }],
                               duration: 4))
    }

    private func postPermissionAlert() {
        alerts.post(NotchAlert(symbol: "lock.shield", tint: Tokens.attention,
                               title: "Orbit needs Screen Recording",
                               subtitle: "Turn on Orbit, then reopen it",
                               actions: [.init(title: "Open Settings", isPrimary: true) { CaptureFiles.openScreenRecordingSettings() }],
                               duration: 10))
    }

    // MARK: Views

    var peekChip: PeekChip? {
        guard isRecording else { return nil }
        return PeekChip(symbol: "record.circle", text: "Recording \(Self.clock(recordingElapsed))",
                        tint: Tokens.error, priority: 7)
    }

    var peekView: AnyView? {
        guard isRecording else { return nil }
        return AnyView(HStack(spacing: 6) {
            Circle().fill(Tokens.error).frame(width: 8, height: 8)
            Text(Self.clock(recordingElapsed)).monospacedDigit()
        })
    }
    var peekPriority: Int { isRecording ? 6 : 0 }

    var panel: AnyView { AnyView(CapturePanel(module: self)) }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Panel

struct CapturePanel: View {
    let module: CaptureModule

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                CaptureTile(title: "Area", symbol: "rectangle.dashed") { module.screenshot(.area) }
                    .overlay(alignment: .topTrailing) { areaMenu }
                CaptureTile(title: "Window", symbol: "macwindow") { module.screenshot(.window) }
                CaptureTile(title: "Screen", symbol: "display") { module.screenshot(.screen) }
                CaptureTile(title: "Draw", symbol: "pencil.tip.crop.circle") { module.draw() }
            }
            .frame(height: 96)

            recordRow

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var areaMenu: some View {
        Menu {
            Button("Area") { module.screenshot(.area) }
            Button("Scrolling screenshot") { module.scrollingScreenshot() }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokens.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Tokens.surface2))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(6)
        .help("More area options")
    }

    private var recordRow: some View {
        HStack(spacing: 10) {
            Button(action: module.toggleRecording) {
                HStack(spacing: 8) {
                    Image(systemName: module.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tokens.error)
                    if module.isRecording {
                        Text(module.isStopping ? "Saving recording…" : "Stop recording")
                            .font(.system(size: 12.5, weight: .medium))
                        Text(CaptureModule.clock(module.recordingElapsed))
                            .font(.system(size: 12.5).monospacedDigit())
                            .foregroundStyle(Tokens.secondary)
                    } else {
                        Text("Record a Window or Screen…").font(.system(size: 12.5, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(module.isStopping)

            Button { module.voice.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: module.voice ? "mic.fill" : "mic.slash")
                        .font(.system(size: 11, weight: .semibold))
                    Text(module.voice ? "Voice on" : "Voice off").font(.system(size: 11.5, weight: .medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(module.voice ? Color.white : Tokens.surface2))
                .foregroundStyle(module.voice ? Color.black : Tokens.secondary)
            }
            .buttonStyle(.plain)
            .disabled(module.isRecording)
            .help("Record your microphone with screen recordings")
            .padding(.trailing, 8)
        }
        .frame(height: 40)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Tokens.stroke))
    }

    @ViewBuilder private var footer: some View {
        if module.needsPermission {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(Tokens.attention)
                Text("Orbit needs Screen Recording permission. Turn it on, then reopen Orbit.")
                    .foregroundStyle(Tokens.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                PillButton(title: "Open Settings") { module.openSettings() }
            }
            .font(.system(size: 11.5))
        } else if let message = module.message {
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.error)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Saved where your screenshots go, and on the Shelf to drag anywhere.")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One big square-ish button: icon above a label.
private struct CaptureTile: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .frame(height: 26)
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hovering ? Tokens.surface2 : Tokens.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Tokens.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
