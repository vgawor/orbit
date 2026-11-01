import AVFoundation
import CoreAudio
import Foundation

/// Small, synchronous CoreAudio helpers for the default input device. All calls are cheap
/// property reads/writes, so the Mic module calls them from the main actor once a second.
enum MicHardware {
    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    /// True when any process (including us) is doing IO on the device.
    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        readUInt32(device, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal) ?? 0 != 0
    }

    // MARK: Mute

    /// The input elements that carry a property: main first, then the first two channels.
    private static let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    private static func settableElements(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        var result: [AudioObjectPropertyElement] = []
        for element in elements {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue {
                result.append(element)
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return result
    }

    static func supportsMute(_ device: AudioDeviceID) -> Bool {
        !settableElements(device, kAudioDevicePropertyMute).isEmpty
    }

    static func supportsVolume(_ device: AudioDeviceID) -> Bool {
        !settableElements(device, kAudioDevicePropertyVolumeScalar).isEmpty
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool? {
        guard let element = settableElements(device, kAudioDevicePropertyMute).first else { return nil }
        return readUInt32(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput, element).map { $0 != 0 }
    }

    @discardableResult
    static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        let targets = settableElements(device, kAudioDevicePropertyMute)
        guard !targets.isEmpty else { return false }
        var ok = true
        for element in targets {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput, mElement: element)
            var value: UInt32 = muted ? 1 : 0
            ok = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr && ok
        }
        return ok
    }

    /// Input volume 0…1 (the first settable element), or nil when the device has none.
    static func inputVolume(_ device: AudioDeviceID) -> Float? {
        guard let element = settableElements(device, kAudioDevicePropertyVolumeScalar).first else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    static func setInputVolume(_ device: AudioDeviceID, _ volume: Float) -> Bool {
        let targets = settableElements(device, kAudioDevicePropertyVolumeScalar)
        guard !targets.isEmpty else { return false }
        var ok = true
        for element in targets {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: element)
            var value = Float32(min(max(volume, 0), 1))
            ok = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr && ok
        }
        return ok
    }

    // MARK: Which processes record (macOS 14.2+)

    struct InputProcess: Equatable {
        let pid: pid_t
        let bundleID: String?
    }

    /// Processes other than us that are recording right now. Nil when the OS can't tell (before 14.2).
    static func otherProcessesRecording() -> [InputProcess]? {
        guard #available(macOS 14.2, *) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return nil }

        let me = getpid()
        var result: [InputProcess] = []
        for object in objects {
            guard readUInt32(object, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal) ?? 0 != 0 else { continue }
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid != me else { continue }

            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let bundleID = AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr
                ? bundle?.takeRetainedValue() as String? : nil
            result.append(InputProcess(pid: pid, bundleID: bundleID))
        }
        return result
    }

    private static func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                   _ scope: AudioObjectPropertyScope,
                                   _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}

/// Measures the input level with an AVAudioEngine tap. Lives off the main actor on purpose:
/// the tap block runs on the audio thread, so it must not be created in a main-actor context
/// (Swift 6 would otherwise insert a main-queue assertion and crash).
final class MicLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?

    var isRunning: Bool { lock.withLock { engine != nil } }

    /// Starts the tap. `onLevel` gets the RMS level in dB (about -160…0), ~10 times a second, on the main actor.
    /// Returns false when the engine couldn't start (no input, no permission).
    func start(onLevel: @escaping @MainActor @Sendable (Float) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard engine == nil else { return true }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        let frames = AVAudioFrameCount(max(1024, format.sampleRate / 10))
        input.installTap(onBus: 0, bufferSize: frames, format: format, block: Self.makeTap(onLevel))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
        self.engine = engine
        return true
    }

    func stop() {
        lock.lock()
        let engine = self.engine
        self.engine = nil
        lock.unlock()
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private static func makeTap(_ onLevel: @escaping @MainActor @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let db = rmsDecibels(buffer)
            Task { @MainActor in onLevel(db) }
        }
    }

    private static func rmsDecibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return -160 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return -160 }
        var peak: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            let samples = channels[c]
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            peak = max(peak, (sum / Float(count)).squareRoot())
        }
        return peak > 0 ? max(-160, 20 * log10(peak)) : -160
    }
}
