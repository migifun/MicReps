@preconcurrency import AVFAudio

/// 届いた音を 48kHz モノラルの CAF(PCM)へ書く。
/// CAF(PCM)は、録音中に強制終了しても書けたところまで読める。
/// 音声スレッドから呼ばれるため、すべての状態をロックで守る。
final class CaptureWriter: @unchecked Sendable {
    static let sampleRate = 48_000.0
    private static let levelWindow = 2_400 // 50ms

    struct Snapshot: Sendable {
        var frames: Int64
        var levels: [Float]
        /// これまでに測った音量の総数(levelsは直近だけ)。
        var measured: Int
        var error: String?
        var duration: Double { Double(frames) / CaptureWriter.sampleRate }
    }

    private let lock = NSLock()
    private let mono = AVAudioFormat(standardFormatWithSampleRate: CaptureWriter.sampleRate, channels: 1)!
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var frames: Int64 = 0
    private var levels: [Float] = []
    private var measured = 0
    private var peak: Float = 0
    private var peakFrames = 0
    private var error: String?

    init(url: URL) throws {
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, error == nil, buffer.frameLength > 0 else { return }
        do {
            let output = try resample(try mixToMono(buffer))
            guard output.frameLength > 0 else { return }
            try file.write(from: output)
            frames += Int64(output.frameLength)
            measure(output)
        } catch {
            self.error = error.localizedDescription
        }
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(frames: frames, levels: levels, measured: measured, error: error)
    }

    @discardableResult
    func close() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        file?.close()
        file = nil
        return Snapshot(frames: frames, levels: levels, measured: measured, error: error)
    }

    private func mixToMono(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let source = buffer.floatChannelData,
              let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength)
        else { throw WriterError.unsupportedFormat }
        let channels = Int(buffer.format.channelCount)
        let count = Int(buffer.frameLength)
        let interleaved = buffer.format.isInterleaved
        // 多チャンネル機器ではマイクが1chだけのことが多いので、割り過ぎて音が小さくならないようにする。
        let scale = 1 / Float(min(channels, 2))
        let target = output.floatChannelData![0]
        for i in 0..<count {
            var sum: Float = 0
            for c in 0..<channels {
                sum += interleaved ? source[0][i * channels + c] : source[c][i * buffer.stride]
            }
            target[i] = max(-1, min(1, sum * scale))
        }
        output.frameLength = buffer.frameLength
        return output
    }

    private func resample(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format.sampleRate == Self.sampleRate {
            converter = nil
            return buffer
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: mono)
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 1024
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) else {
            throw WriterError.unsupportedFormat
        }
        nonisolated(unsafe) var supplied = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let failure { throw failure }
        return output
    }

    private func measure(_ buffer: AVAudioPCMBuffer) {
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(samples[i]))
            peakFrames += 1
            if peakFrames == Self.levelWindow {
                levels.append(peak)
                measured += 1
                peak = 0
                peakFrames = 0
            }
        }
        if levels.count > 400 { levels.removeFirst(levels.count - 400) }
    }

    enum WriterError: LocalizedError {
        case unsupportedFormat
        var errorDescription: String? { "マイクの音声形式に対応していません。" }
    }
}
