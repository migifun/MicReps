@preconcurrency import AVFAudio
import AVFoundation
import CoreAudio

enum CaptureInterruption: Sendable {
    /// 入力機器は同じだが、形式などが変わって入力が止まった。
    case configurationChanged
    /// 既定の入力機器が別のものに変わった(マイクが外れたなど)。
    case deviceChanged
}

enum CaptureError: LocalizedError {
    case noInput

    var errorDescription: String? { "使えるマイクが見つかりません。" }
}

/// 音の入力元。テストでは合成音に差し替える。
protocol AudioCapture: AnyObject {
    /// 今使われるマイクの名前。
    var inputName: String? { get }
    nonisolated(nonsending) func requestPermission() async -> Bool
    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onInterruption: @escaping @Sendable (CaptureInterruption) -> Void
    ) throws
    func stop()
}

extension AudioCapture {
    var inputName: String? { nil }
}

/// 一時停止のたびに完全に止め、再開時に作り直す。止めている間はマイクを使わない。
final class MicrophoneCapture: AudioCapture {
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    nonisolated(nonsending) func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onInterruption: @escaping @Sendable (CaptureInterruption) -> Void
    ) throws {
        stop()
        let device = Self.defaultInputDevice()
        guard device != kAudioObjectUnknown else { throw CaptureError.noInput }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }

        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in onBuffer(buffer) }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            onInterruption(Self.defaultInputDevice() == device ? .configurationChanged : .deviceChanged)
        }
        self.engine = engine
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    var inputName: String? {
        let device = Self.defaultInputDevice()
        guard device != kAudioObjectUnknown else { return nil }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func defaultInputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
}

#if DEBUG
/// マイクを使わずに動作確認するための合成音。実時間で 100ms ずつ流す。
final class SyntheticCapture: AudioCapture {
    private var timer: DispatchSourceTimer?

    nonisolated(nonsending) func requestPermission() async -> Bool { true }

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onInterruption: @escaping @Sendable (CaptureInterruption) -> Void
    ) throws {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "synthetic"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        nonisolated(unsafe) var tick = 0
        timer.setEventHandler { @Sendable in
            onBuffer(Self.tone(tick: tick))
            tick += 1
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private static func tone(tick: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        let gain = 0.05 + 0.3 * abs(sinf(Float(tick) * 0.35) * sinf(Float(tick) * 0.11))
        for i in 0..<4800 {
            buffer.floatChannelData![0][i] = gain * sinf(Float(i) * 2 * .pi * 220 / 48_000)
        }
        return buffer
    }
}
#endif
