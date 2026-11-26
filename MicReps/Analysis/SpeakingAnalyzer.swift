import Foundation

/// 音声と文字起こしから、話し方の分析結果を作る。
enum SpeakingAnalyzer {
    static let minimumPause = 0.3
    static let contourPoints = 600
    /// 語尾として見る長さ(秒)。
    static let tail = 0.6

    @concurrent
    static func analyze(
        _ url: URL, sentences: [Sentence], onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> SpeakingAnalysis {
        let frames = try VoiceMeter.measure(url) { onProgress($0 * 0.9) }
        let result = analyze(frames, sentences: sentences)
        onProgress(1)
        return result
    }

    static func analyze(_ frames: VoiceFrames, sentences: [Sentence]) -> SpeakingAnalysis {
        let levels = frames.level.sorted()
        let floor = levels.isEmpty ? -90 : levels[levels.count / 10]
        let peak = levels.isEmpty ? -90 : levels[min(levels.count - 1, levels.count * 99 / 100)]
        // 雑音と話し声の差が小さい録音では、雑音のすぐ上を基準にする。
        let threshold = peak - floor >= 10 ? floor + (peak - floor) * 0.25 : floor + 3

        let speechStart = sentences.first?.start ?? 0
        let speechEnd = sentences.last?.end ?? frames.duration
        let pauses = findPauses(frames, threshold: threshold).filter {
            $0.start >= speechStart - 0.05 && $0.start + $0.length <= speechEnd + 0.3
        }
        let silent = pauses.filter { $0.length >= SpeakingAnalysis.silenceLimit }.reduce(0) { $0 + $1.length }
        let voicedPitch = zip(frames.level, frames.pitch).compactMap { $0 > threshold && $1 > 0 ? $1 : nil }
        let medianPitch = SpeakingAnalysis.median(voicedPitch) ?? 0
        let graph = contour(frames, threshold: threshold, medianPitch: medianPitch)
        let fillers = FillerDetector.fillers(in: sentences)

        return SpeakingAnalysis(
            duration: frames.duration,
            speakingTime: max(0, speechEnd - speechStart - silent),
            noiseFloor: floor,
            silenceThreshold: threshold,
            pauses: pauses,
            fillers: fillers,
            habits: FillerDetector.habits(in: sentences),
            sentences: sentences.map { voice(of: $0, frames, threshold: threshold, pauses: pauses) },
            pitchContour: graph.pitch,
            volumeContour: graph.volume,
            issues: SentenceRules.issues(SpokenSentence.build(sentences, fillers: fillers))
        )
    }

    static func findPauses(_ frames: VoiceFrames, threshold: Float) -> [SpeakingAnalysis.Pause] {
        var result: [SpeakingAnalysis.Pause] = []
        var start: Int?
        for i in 0...frames.count {
            let quiet = i < frames.count && frames.level[i] < threshold
            if quiet {
                if start == nil { start = i }
            } else if let from = start {
                let length = Double(i - from) * VoiceFrames.hop
                if length >= minimumPause {
                    result.append(.init(start: Double(from) * VoiceFrames.hop, length: (length * 100).rounded() / 100))
                }
                start = nil
            }
        }
        return result
    }

    private static func voice(
        of sentence: Sentence, _ frames: VoiceFrames, threshold: Float, pauses: [SpeakingAnalysis.Pause]
    ) -> SpeakingAnalysis.SentenceVoice {
        let range = frames.frame(at: sentence.start)..<frames.frame(at: sentence.end)
        let voiced = range.filter { frames.level[$0] > threshold }
        guard !voiced.isEmpty else { return .init() }

        let pitches = voiced.map { frames.pitch[$0] }.filter { $0 > 0 }
        var pitch: Float?
        var pitchRange: Float?
        if pitches.count >= 10, let median = SpeakingAnalysis.median(pitches) {
            pitch = median
            let semitones = pitches.map { 12 * log2($0 / median) }.sorted()
            pitchRange = semitones[semitones.count * 9 / 10] - semitones[semitones.count / 10]
        }

        let levels = voiced.map { frames.level[$0] }
        let volume = levels.reduce(0, +) / Float(levels.count)
        let tailFrom = frames.frame(at: sentence.end - tail)
        let tailLevels = voiced.filter { $0 >= tailFrom }.map { frames.level[$0] }
        let tailDrop = tailLevels.count >= 5 ? tailLevels.reduce(0, +) / Float(tailLevels.count) - volume : nil

        // 文の中の間を除いた、声を出していた時間で割る。
        let paused = pauses.reduce(0.0) { total, pause in
            let overlap = min(sentence.end, pause.start + pause.length) - max(sentence.start, pause.start)
            return total + max(0, overlap)
        }
        let spoken = sentence.end - sentence.start - paused
        let morae = MoraCounter.count(sentence.text)
        let rate: Float? = spoken >= 1 && morae > 0 ? Float(Double(morae) / spoken) : nil

        return .init(pitch: pitch, pitchRange: pitchRange, volume: volume, tailDrop: tailDrop, rate: rate)
    }

    private static func contour(
        _ frames: VoiceFrames, threshold: Float, medianPitch: Float
    ) -> (pitch: [Float?], volume: [Float]) {
        guard frames.count > 0 else { return ([], []) }
        let points = min(contourPoints, frames.count)
        var pitch: [Float?] = []
        var volume: [Float] = []
        for p in 0..<points {
            let lower = p * frames.count / points
            let upper = max(lower + 1, (p + 1) * frames.count / points)
            let slice = lower..<min(upper, frames.count)
            volume.append(slice.map { frames.level[$0] }.max() ?? threshold)
            let voiced = slice.filter { frames.level[$0] > threshold && frames.pitch[$0] > 0 }.map { frames.pitch[$0] }
            if voiced.count >= 3, medianPitch > 0, let median = SpeakingAnalysis.median(voiced) {
                pitch.append(12 * log2(median / medianPitch))
            } else {
                pitch.append(nil)
            }
        }
        return (pitch, volume)
    }
}
