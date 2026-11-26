@preconcurrency import AVFAudio
import Foundation
import SwiftData
@testable import MicReps

func tone(rate: Double = 48_000, channels: AVAudioChannelCount = 1, seconds: Double, gain: Float = 0.3) -> AVAudioPCMBuffer {
    // 3ch以上は並び順の情報が必要。
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    let count = AVAudioFrameCount(rate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
    buffer.frameLength = count
    for c in 0..<Int(channels) where gain != 0 {
        for i in 0..<Int(count) {
            buffer.floatChannelData![c][i] = gain * sinf(Float(i) * 2 * .pi * 220 / Float(rate))
        }
    }
    return buffer
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

func makePaths() throws -> AppPaths {
    let paths = AppPaths(root: FileManager.default.temporaryDirectory.appending(path: "MRTest-\(UUID().uuidString)"))
    try paths.createDirectories()
    return paths
}

@MainActor
func makeStore(_ paths: AppPaths) throws -> RecordingStore {
    let container = try ModelContainer(for: Recording.self, configurations: ModelConfiguration(url: paths.database))
    return RecordingStore(paths: paths, container: container)
}

/// 手で音や割り込みを流し込める入力。
final class FakeCapture: AudioCapture {
    var permission = true
    var startError: Error?
    var starts = 0
    var stops = 0
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onInterruption: (@Sendable (CaptureInterruption) -> Void)?

    nonisolated(nonsending) func requestPermission() async -> Bool { permission }

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onInterruption: @escaping @Sendable (CaptureInterruption) -> Void
    ) throws {
        if let startError { throw startError }
        starts += 1
        self.onBuffer = onBuffer
        self.onInterruption = onInterruption
    }

    func stop() {
        stops += 1
        onBuffer = nil
    }
}

/// 結果や失敗を差し込める文字起こし。
final class FakeTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<[TimedText], Error> = .success([TimedText(text: "こんにちは。", start: 0, end: 1)])
    private var _calls: [URL] = []
    private var _running = 0
    private var _maxRunning = 0
    private var _installs = 0
    private var _beforeReturn: @Sendable () async -> Void = {}

    var result: Result<[TimedText], Error> {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }
    var beforeReturn: @Sendable () async -> Void {
        get { lock.withLock { _beforeReturn } }
        set { lock.withLock { _beforeReturn = newValue } }
    }
    var calls: [URL] { lock.withLock { _calls } }
    var maxRunning: Int { lock.withLock { _maxRunning } }
    var installs: Int { lock.withLock { _installs } }

    func transcribe(
        _ url: URL, locale: Locale, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedText] {
        lock.withLock {
            _calls.append(url)
            _running += 1
            _maxRunning = max(_maxRunning, _running)
        }
        onProgress(0.5)
        try? await Task.sleep(for: .milliseconds(20))
        await beforeReturn()
        lock.withLock { _running -= 1 }
        return try result.get()
    }

    func installModel(for locale: Locale) async throws { lock.withLock { _installs += 1 } }
    func supportedLocales() async -> [Locale] { [Locale(identifier: "ja-JP")] }
}

/// 答えを差し込めるAI。
final class FakeGenerator: ChapterGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var _answer: @Sendable ([String]) throws -> [ChapterProposal] = { _ in [] }
    private var _reason: String?
    private var _windows: [[String]] = []

    var answer: @Sendable ([String]) throws -> [ChapterProposal] {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }
    var reason: String? {
        get { lock.withLock { _reason } }
        set { lock.withLock { _reason = newValue } }
    }
    var windows: [[String]] { lock.withLock { _windows } }
    var calls: Int { windows.count }

    func unavailableReason(for locale: Locale) -> String? { reason }

    /// 答えは常に「最初の文」で書く。行番号で聞かれたときは、番号に直して返す。
    func propose(
        _ sentences: [String], firstLine: Int, question: ChapterQuestion, locale: Locale
    ) async throws -> [ChapterProposal] {
        lock.withLock { _windows.append(sentences) }
        let proposals = try answer(sentences)
        guard question == .lineNumber else { return proposals }
        return proposals.map { proposal in
            let line = sentences.firstIndex { $0 == proposal.firstSentence }.map { $0 + firstLine }
            return ChapterProposal(title: proposal.title, line: line ?? 99_999)
        }
    }
}

/// 文の見直しの代わり。「雑談」を含む文を脱線とし、言い直しは先頭に「例:」を付けて返す。
final class FakeReviewer: SentenceReviewer, @unchecked Sendable {
    private let lock = NSLock()
    private var _reason: String?
    private var _refused: Set<String> = []
    private var _roles = 0
    private var _rewrites = 0

    var reason: String? {
        get { lock.withLock { _reason } }
        set { lock.withLock { _reason = newValue } }
    }
    /// この文字列を含む文には答えない。
    var refused: Set<String> {
        get { lock.withLock { _refused } }
        set { lock.withLock { _refused = newValue } }
    }
    var roleCalls: Int { lock.withLock { _roles } }
    var rewriteCalls: Int { lock.withLock { _rewrites } }

    func unavailableReason(for locale: Locale) -> String? { reason }

    func role(of sentence: String, topic: String) async throws -> SentenceRole {
        lock.withLock { _roles += 1 }
        if refused.contains(where: { sentence.contains($0) }) { throw ReviewError.refused }
        return sentence.contains("雑談") ? .aside : .main
    }

    func rewrite(_ sentence: String) async throws -> String {
        lock.withLock { _rewrites += 1 }
        if refused.contains(where: { sentence.contains($0) }) { throw ReviewError.refused }
        return "例:" + sentence.prefix(10)
    }
}
