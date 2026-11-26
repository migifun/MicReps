@preconcurrency import AVFAudio

/// 録音した CAF を m4a に変換し、正しく読めることを確かめる。元の CAF は消さない(呼び出し側が保存後に消す)。
enum AudioFinalizer {
    struct Output: Sendable {
        var duration: Double
        var waveform: [Float]
    }

    enum Failure: LocalizedError {
        case missing, empty, verification
        var errorDescription: String? {
            switch self {
            case .missing: "音声ファイルが見つかりません。"
            case .empty: "音声が記録されていません。"
            case .verification: "変換後の音声を確認できませんでした。"
            }
        }
    }

    static let waveformBuckets = 600

    @concurrent
    static func finalize(caf: URL, m4a: URL) async throws -> Output {
        let files = FileManager.default
        guard files.fileExists(atPath: caf.path(percentEncoded: false)) else {
            guard files.fileExists(atPath: m4a.path(percentEncoded: false)) else { throw Failure.missing }
            return try analyze(m4a)
        }
        let partial = m4a.deletingPathExtension().appendingPathExtension("partial.m4a")
        try? files.removeItem(at: partial)
        do {
            let source = try convert(from: caf, to: partial)
            let result = try AVAudioFile(forReading: partial)
            let duration = Double(result.length) / result.processingFormat.sampleRate
            guard abs(duration - source.duration) < 0.25 else { throw Failure.verification }
            result.close()
            if files.fileExists(atPath: m4a.path(percentEncoded: false)) {
                _ = try files.replaceItemAt(m4a, withItemAt: partial)
            } else {
                try files.moveItem(at: partial, to: m4a)
            }
            return source
        } catch {
            try? files.removeItem(at: partial)
            throw error
        }
    }

    private static func convert(from source: URL, to target: URL) throws -> Output {
        let input = try AVAudioFile(forReading: source)
        guard input.length > 0 else { throw Failure.empty }
        let output = try AVAudioFile(forWriting: target, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: input.processingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ])
        defer { output.close() }
        return try read(input) { try output.write(from: $0) }
    }

    private static func analyze(_ url: URL) throws -> Output {
        let input = try AVAudioFile(forReading: url)
        guard input.length > 0 else { throw Failure.empty }
        return try read(input) { _ in }
    }

    private static func read(_ input: AVAudioFile, each: (AVAudioPCMBuffer) throws -> Void) throws -> Output {
        let total = input.length
        let perBucket = max(1, Int((total + Int64(waveformBuckets) - 1) / Int64(waveformBuckets)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536) else {
            throw Failure.empty
        }
        var waveform: [Float] = []
        var peak: Float = 0
        var inBucket = 0
        var frames: Int64 = 0
        while input.framePosition < total {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try each(buffer)
            frames += Int64(buffer.frameLength)
            let samples = buffer.floatChannelData![0]
            for i in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(samples[i]))
                inBucket += 1
                if inBucket == perBucket {
                    waveform.append(peak)
                    peak = 0
                    inBucket = 0
                }
            }
        }
        if inBucket > 0 { waveform.append(peak) }
        return Output(duration: Double(frames) / input.processingFormat.sampleRate, waveform: waveform)
    }
}
