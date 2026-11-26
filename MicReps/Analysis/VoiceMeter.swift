@preconcurrency import AVFAudio
import Accelerate
import Foundation

/// 20ミリ秒ごとの声の大きさと高さ。
struct VoiceFrames: Sendable {
    static let hop = 0.02
    /// 大きさ(dB)。
    var level: [Float]
    /// 声の高さ(Hz)。声が無いフレームは 0。
    var pitch: [Float]

    var count: Int { level.count }
    var duration: Double { Double(count) * Self.hop }

    func frame(at time: Double) -> Int { min(max(0, Int(time / Self.hop)), count) }
}

enum VoiceMeterError: LocalizedError {
    case unreadable

    var errorDescription: String? { "音声を読み込めませんでした。" }
}

/// 音声ファイルを少しずつ読み、大きさと声の高さ(YIN法)を測る。長い録音でもメモリを使いすぎない。
enum VoiceMeter {
    static let sampleRate = 16000.0
    private static let hop = Int(sampleRate * VoiceFrames.hop)
    private static let window = 1024
    /// 人の声の高さとして探す範囲(60〜500Hz)。
    private static let minimumLag = Int(sampleRate / 500)
    private static let maximumLag = Int(sampleRate / 60)
    private static let threshold: Float = 0.15
    /// これより小さい音では高さを測らない(無音の雑音を声と取り違えないため)。
    private static let quietest: Float = 0.003

    static func measure(_ url: URL, onProgress: @Sendable (Double) -> Void = { _ in }) throws -> VoiceFrames {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw VoiceMeterError.unreadable }
        let source = file.processingFormat
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: source, to: target) else { throw VoiceMeterError.unreadable }
        converter.downmix = true

        let chunk: AVAudioFrameCount = 32768
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk),
              let output = AVAudioPCMBuffer(
                  pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(chunk) * sampleRate / source.sampleRate) + 1024
              ) else { throw VoiceMeterError.unreadable }

        var frames = VoiceFrames(level: [], pitch: [])
        let total = max(1, Double(file.length))
        frames.level.reserveCapacity(Int(Double(file.length) / source.sampleRate / VoiceFrames.hop) + 1)
        frames.pitch.reserveCapacity(frames.level.capacity)
        var samples: [Float] = []
        var reachedEnd = false
        var scratch = [Float](repeating: 0, count: window)
        var difference = [Float](repeating: 0, count: maximumLag + 1)

        while !reachedEnd {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                do {
                    input.frameLength = 0
                    try file.read(into: input, frameCount: chunk)
                } catch {
                    input.frameLength = 0
                }
                if input.frameLength == 0 {
                    state.pointee = .endOfStream
                    return nil
                }
                state.pointee = .haveData
                return input
            }
            if status == .error { throw VoiceMeterError.unreadable }
            if status == .endOfStream || (status == .inputRanDry && output.frameLength == 0) { reachedEnd = true }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }

            var position = 0
            while position + window + maximumLag <= samples.count {
                samples.withUnsafeBufferPointer { buffer in
                    let base = buffer.baseAddress! + position
                    var rms: Float = 0
                    vDSP_rmsqv(base, 1, &rms, vDSP_Length(window))
                    frames.level.append(20 * log10(max(rms, 1e-6)))
                    frames.pitch.append(rms >= quietest ? pitch(base, &scratch, &difference) : 0)
                }
                position += hop
            }
            samples.removeFirst(position)
            onProgress(min(1, Double(file.framePosition) / total))
        }
        return frames
    }

    /// YIN法。見つからなければ 0。
    private static func pitch(_ base: UnsafePointer<Float>, _ scratch: inout [Float], _ difference: inout [Float]) -> Float {
        for lag in 1...maximumLag {
            vDSP_vsub(base, 1, base + lag, 1, &scratch, 1, vDSP_Length(window))
            var sum: Float = 0
            vDSP_svesq(scratch, 1, &sum, vDSP_Length(window))
            difference[lag] = sum
        }
        var cumulative: Float = 0
        for lag in 1...maximumLag {
            cumulative += difference[lag]
            let normalized = cumulative > 0 ? difference[lag] * Float(lag) / cumulative : 1
            guard lag >= minimumLag, normalized < threshold else { continue }
            var best = lag
            while best + 1 <= maximumLag, difference[best + 1] < difference[best] { best += 1 }
            return Float(sampleRate) / Float(best)
        }
        return 0
    }
}
