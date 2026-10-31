import AppKit
@preconcurrency import AVFoundation
import CoreImage
import SwiftUI

/// Check how you look before a call: a live, mirrored front-camera preview with a few looks.
/// The camera only runs while the Mirror panel is on screen.
@MainActor
@Observable
final class MirrorModule: NotchModule {
    let id = "mirror"
    let title = "Mirror"
    let symbol = "person.crop.square"

    enum Effect: String, CaseIterable, Identifiable {
        case normal = "Normal", warm = "Warm", mono = "Mono", soft = "Soft"
        var id: String { rawValue }
    }

    var effect: Effect = Effect(rawValue: UserDefaults.standard.string(forKey: "mirror.effect") ?? "") ?? .normal {
        didSet { UserDefaults.standard.set(effect.rawValue, forKey: "mirror.effect") }
    }
    private(set) var status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var hasCamera = true
    private(set) var isRunning = false

    let camera = MirrorCamera()

    /// Called when the panel appears.
    func show() {
        status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            startCamera()
        case .notDetermined:
            Task {
                let ok = await AVCaptureDevice.requestAccess(for: .video)
                self.status = ok ? .authorized : .denied
                if ok { self.startCamera() }
            }
        default:
            break
        }
    }

    /// Called when the panel disappears.
    func hide() {
        camera.stop()
        isRunning = false
    }

    private func startCamera() {
        hasCamera = camera.configureIfNeeded()
        guard hasCamera else { return }
        camera.start()
        isRunning = true
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() { hide() }

    var panel: AnyView { AnyView(MirrorPanel(module: self)) }
}

/// Owns the capture session. Starting/stopping happens on a private queue because it blocks.
final class MirrorCamera: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "viktor.mirror.camera")
    private var configured = false

    /// Adds the front (or default) camera. Returns false when there is no camera.
    @MainActor
    func configureIfNeeded() -> Bool {
        if configured { return true }
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.high) ? .high : .medium
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        configured = true
        return true
    }

    func start() {
        queue.async { [session] in if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }
}

// MARK: - Panel

struct MirrorPanel: View {
    let module: MirrorModule

    var body: some View {
        HStack(spacing: 16) {
            preview
                .frame(width: 300)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 10) {
                CardLabel("Mirror")
                Text("Check how you look before the call.")
                    .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                CardLabel("Look")
                HStack(spacing: 6) {
                    ForEach(MirrorModule.Effect.allCases) { e in
                        Button(e.rawValue) { module.effect = e }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(module.effect == e ? Color.white : Tokens.surface2))
                            .foregroundStyle(module.effect == e ? Color.black : Tokens.secondary)
                    }
                }
                Spacer(minLength: 0)
                if module.isRunning {
                    Label("Camera on while this tab is open", systemImage: "circle.fill")
                        .labelStyle(DotLabel(color: Tokens.live))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { module.show() }
        .onDisappear { module.hide() }
    }

    @ViewBuilder private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            switch module.status {
            case .authorized where module.hasCamera:
                CameraPreview(session: module.camera.session, effect: module.effect)
            case .authorized:
                message(symbol: "video.slash", text: "No camera found")
            case .notDetermined:
                message(symbol: "video", text: "Asking for camera access…")
            default:
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.system(size: 20)).foregroundStyle(Tokens.secondary)
                    Text("Orbit needs camera permission")
                        .font(.system(size: 12, weight: .medium))
                    PillButton(title: "Open System Settings") { module.openPrivacySettings() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Tokens.surface)
        .clipShape(shape)
        .overlay(shape.stroke(Tokens.stroke))
    }

    private func message(symbol: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Tokens.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// AVCaptureVideoPreviewLayer in a layer-hosting view, mirrored, aspect-fill,
/// with Core Image filters applied to the layer for the looks.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let effect: MirrorModule.Effect

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.apply(effect)
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        view.apply(effect)
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        private var current: MirrorModule.Effect?

        override init(frame: NSRect) {
            super.init(frame: frame)
            layerUsesCoreImageFilters = true
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
            mirror()
        }

        /// Selfie view: flip horizontally (via the connection when possible, else the layer).
        private func mirror() {
            if let c = previewLayer.connection, c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true
                previewLayer.setAffineTransform(.identity)
            } else {
                previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            }
        }

        func apply(_ effect: MirrorModule.Effect) {
            mirror()
            guard effect != current else { return }
            current = effect
            previewLayer.filters = Self.filters(for: effect)
        }

        static func filters(for effect: MirrorModule.Effect) -> [CIFilter]? {
            switch effect {
            case .normal:
                return nil
            case .warm:
                guard let f = CIFilter(name: "CITemperatureAndTint") else { return nil }
                f.setDefaults()
                f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                f.setValue(CIVector(x: 5200, y: 10), forKey: "inputTargetNeutral")
                return [f]
            case .mono:
                guard let f = CIFilter(name: "CIColorControls") else { return nil }
                f.setDefaults()
                f.setValue(0.0, forKey: kCIInputSaturationKey)
                f.setValue(1.08, forKey: kCIInputContrastKey)
                return [f]
            case .soft:
                guard let c = CIFilter(name: "CIColorControls"), let b = CIFilter(name: "CIGaussianBlur") else { return nil }
                c.setDefaults()
                c.setValue(0.9, forKey: kCIInputContrastKey)
                c.setValue(0.04, forKey: kCIInputBrightnessKey)
                c.setValue(0.92, forKey: kCIInputSaturationKey)
                b.setDefaults()
                b.setValue(1.2, forKey: kCIInputRadiusKey)
                return [c, b]
            }
        }
    }
}
