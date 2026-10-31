import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Shows the system window/screen picker (macOS 14+) and hands back the chosen content.
@MainActor
final class RecordingPicker {
    private var observer: PickerObserver?

    /// `completion` gets the chosen filter, or nil when cancelled, or an error.
    func present(completion: @escaping @MainActor (Result<FilterBox, Error>?) -> Void) {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleDisplay]
        config.allowsChangingSelectedContent = false
        picker.defaultConfiguration = config

        let observer = PickerObserver { [weak self] result in
            Task { @MainActor in
                self?.teardown()
                completion(result)
            }
        }
        if let old = self.observer { picker.remove(old) }
        self.observer = observer
        picker.add(observer)
        picker.isActive = true
        picker.present()
    }

    func teardown() {
        let picker = SCContentSharingPicker.shared
        if let observer { picker.remove(observer) }
        observer = nil
        picker.isActive = false
    }
}

private final class PickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private let done: @Sendable (Result<FilterBox, Error>?) -> Void
    private let lock = NSLock()
    private var fired = false

    init(done: @escaping @Sendable (Result<FilterBox, Error>?) -> Void) { self.done = done }

    private func fire(_ result: Result<FilterBox, Error>?) {
        lock.lock(); defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        done(result)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) { fire(nil) }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        fire(.success(FilterBox(filter: filter)))
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) { fire(.failure(error)) }
}

/// Records the picked window or screen to a .mov with SCRecordingOutput (macOS 15+),
/// optionally with the microphone.
@available(macOS 15.0, *)
final class ScreenRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let url: URL
    private let stream: SCStream
    private let recording: SCRecordingOutput
    private let onFinish: @Sendable (Result<URL, Error>) -> Void
    private let lock = NSLock()
    private var finished = false
    private let queue = DispatchQueue(label: "viktor.capture.recording")

    init(filter: SCContentFilter, microphone: Bool, url: URL,
         onFinish: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.url = url
        self.onFinish = onFinish

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(2, Int((filter.contentRect.width * scale).rounded()))
        config.height = max(2, Int((filter.contentRect.height * scale).rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.queueDepth = 6
        config.captureMicrophone = microphone

        let outConfig = SCRecordingOutputConfiguration()
        outConfig.outputURL = url
        outConfig.outputFileType = .mov
        outConfig.videoCodecType = .h264

        // Delegates are set after super.init via the setters below.
        let placeholder = RecorderDelegateProxy()
        stream = SCStream(filter: filter, configuration: config, delegate: placeholder)
        recording = SCRecordingOutput(configuration: outConfig, delegate: placeholder)
        super.init()
        placeholder.target = self
        proxy = placeholder
    }

    private var proxy: RecorderDelegateProxy?

    /// Starts capturing; `started` gets nil on success or the error.
    func start(_ started: @escaping @Sendable (Error?) -> Void) {
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try stream.addRecordingOutput(recording)
        } catch {
            started(error)
            return
        }
        stream.startCapture { error in started(error) }
    }

    func stop() {
        stream.stopCapture { [weak self] error in
            guard let self else { return }
            // The recording output normally reports the finished file; this is a fallback.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if let error, !self.fileLooksGood { self.finish(.failure(error)) } else { self.finish(.success(self.url)) }
            }
        }
    }

    private var fileLooksGood: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size > 0
    }

    fileprivate func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        if first { onFinish(result) }
    }

    // MARK: Delegates (forwarded from the proxy)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    fileprivate func streamStopped(_ error: Error) {
        // e.g. the user pressed "Stop sharing" in the menu bar: keep what was recorded.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            self.finish(self.fileLooksGood ? .success(self.url) : .failure(error))
        }
    }
}

/// SCStream and SCRecordingOutput take their delegate at init, before `self` exists.
@available(macOS 15.0, *)
private final class RecorderDelegateProxy: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    weak var target: ScreenRecorder?

    func stream(_ stream: SCStream, didStopWithError error: any Error) { target?.streamStopped(error) }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        guard let target else { return }
        target.finish(.success(target.url))
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        target?.finish(.failure(error))
    }
}
