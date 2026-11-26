@preconcurrency import AVFAudio
import Foundation
import Testing
@testable import MicReps

/// 1文字ずつ 0.1 秒の時刻を付けた文。
private func sentence(_ text: String, from start: Double = 0) -> Sentence {
    Sentence(start: start, end: start + Double(text.count) * 0.1, text: text,
             times: (0..<text.count).map { start + Double($0) * 0.1 })
}

struct SentenceTimesTests {
    @Test func 空白を取っても文字と時刻がそろう() {
        let pieces = [
            TimedText(text: "全体の", start: 0, end: 0.3), TimedText(text: " ", start: 0.3, end: 0.4),
            TimedText(text: "4割", start: 0.4, end: 0.6), TimedText(text: "。", start: 0.6, end: 0.7),
        ]
        let result = SentenceBuilder.build(pieces)
        #expect(result.map(\.text) == ["全体の4割。"])
        let times = try! #require(result[0].times)
        #expect(times.count == result[0].text.count)
        #expect(abs(times[3] - 0.4) < 0.001)
    }

    @Test func 時刻が無い文は文の中で見積もる() {
        let old = Sentence(start: 10, end: 20, text: "あいうえおかきくけこ")
        #expect(abs(old.time(at: 5) - 15) < 0.001)
        #expect(abs(sentence("あいう", from: 2).time(at: 2) - 2.2) < 0.001)
    }

    @Test func 古い形式の文字起こしも読める() throws {
        let json = #"{"locale":"ja-JP","sentences":[{"start":0,"end":1,"text":"はい。"}]}"#
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        #expect(transcript.sentences[0].times == nil)
    }
}

struct FillerTests {
    private func words(_ text: String) -> [String] {
        FillerDetector.fillers(in: [sentence(text)]).map(\.word)
    }

    @Test func 必ずフィラーになる語を拾う() {
        #expect(words("えーと今日は、えっと、まあ話します。うーん。") == ["えーと", "えっと", "まあ", "うーん"])
        #expect(words("やっぱりえと作りながら") == ["えと"])
    }

    @Test func 指示語は切れ目に挟まれたときだけ数える() {
        #expect(words("あの家に行きます。") == ["あの"])   // 文頭は切れ目とみなす
        #expect(words("実はあの家に行きます。").isEmpty)
        #expect(words("ので、あの実際に") == ["あの"])
        #expect(words("実際あの資料を") == ["あの"])
        #expect(words("それはその通りです。").isEmpty)
        #expect(words("なのかなんかそのあたり") == ["なんか", "その"])
    }

    @Test func 文頭のでも数える() {
        let fillers = FillerDetector.fillers(in: [sentence("で、次の話です。")])
        #expect(fillers.map(\.word) == ["で"])
        #expect(!fillers[0].isCertain)
        #expect(words("でも、いいです。").isEmpty)
    }

    @Test func 位置と時刻は文字起こしの文字に合う() {
        let fillers = FillerDetector.fillers(in: [sentence("はい。"), sentence("今日は、えっと話します。", from: 5)])
        #expect(fillers.count == 1)
        #expect(fillers[0].sentence == 1)
        #expect(fillers[0].offset == 4)
        #expect(fillers[0].length == 3)
        #expect(abs(fillers[0].time - 5.4) < 0.001)
    }

    @Test func 次の文字まで間があれば切れ目とみなす() {
        var paused = sentence("実はその本です。")
        paused.times![4] += 0.8   // 「その」のあとで間が空いた
        for i in 5..<paused.times!.count { paused.times![i] += 0.8 }
        #expect(FillerDetector.fillers(in: [paused]).map(\.word) == ["その"])
    }

    @Test func 口癖を数える() {
        let habits = FillerDetector.habits(in: [
            sentence("実際やっぱり作るっていう。"), sentence("実際やっぱり。"), sentence("実際やっぱ。"),
        ])
        #expect(habits.first == .init(word: "実際", count: 3))
        #expect(habits.contains(.init(word: "やっぱり", count: 2)) == false)   // 3回未満は出さない
        #expect(!habits.contains { $0.word == "やっぱ" })
    }

    @Test func 音の数を読みがなから数える() {
        #expect(MoraCounter.count("今日は") == 3)     // きょ・う・は
        #expect(MoraCounter.count("学校") == 4)       // が・っ・こ・う
        #expect(MoraCounter.count("、。") == 0)
    }
}

struct VoiceMeterTests {
    /// 220Hzの音1秒、無音1.5秒、音1秒のファイル。
    private func makeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).caf")
        let format = tone(seconds: 0.1).format
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: tone(seconds: 1))
        try file.write(from: tone(seconds: 1.5, gain: 0))
        try file.write(from: tone(seconds: 1, gain: 0.1))
        return url
    }

    @Test func 声の高さと間と大きさを測る() async throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try VoiceMeter.measure(url)
        #expect(abs(frames.duration - 3.5) < 0.15)
        let voiced = frames.pitch.filter { $0 > 0 }
        let median = try #require(SpeakingAnalysis.median(voiced))
        #expect(abs(median - 220) < 5)

        let sentences = [
            Sentence(start: 0, end: 1, text: "あいうえお。"), Sentence(start: 2.5, end: 3.5, text: "かきくけこ。"),
        ]
        let analysis = SpeakingAnalyzer.analyze(frames, sentences: sentences)
        let pause = try #require(analysis.pauses.first)
        #expect(abs(pause.start - 1) < 0.1)
        #expect(abs(pause.length - 1.5) < 0.15)
        // 2つ目は10dB小さい(ゲイン 0.3 → 0.1)。
        let first = try #require(analysis.sentences[0].volume)
        let second = try #require(analysis.sentences[1].volume)
        #expect(abs((first - second) - 9.5) < 1)
        // 一定の高さの音なので、抑揚はほぼ無い。
        #expect((analysis.sentences[0].pitchRange ?? 99) < 0.5)
        #expect(analysis.pitchContour.count == min(SpeakingAnalyzer.contourPoints, frames.count))
        #expect(analysis.findings(sentences).contains { $0.kind == .longPause } == false)
    }

    @Test func 話す前と後の無音は間に数えない() {
        let frames = VoiceFrames(
            level: Array(repeating: -80, count: 100) + Array(repeating: -30, count: 100) + Array(repeating: -80, count: 100),
            pitch: Array(repeating: 0, count: 300)
        )
        let analysis = SpeakingAnalyzer.analyze(frames, sentences: [Sentence(start: 2, end: 4, text: "はい。")])
        #expect(analysis.pauses.isEmpty)
        #expect(abs(analysis.speakingTime - 2) < 0.001)
    }

    @Test func 指摘の一覧() {
        let analysis = SpeakingAnalysis(
            duration: 60, speakingTime: 60, noiseFloor: -70, silenceThreshold: -60,
            pauses: [.init(start: 5, length: 2.5), .init(start: 20, length: 12), .init(start: 30, length: 0.5)],
            fillers: [.init(sentence: 0, offset: 0, length: 3, time: 1, word: "えっと", isCertain: true)],
            habits: [],
            sentences: [
                .init(pitch: 150, pitchRange: 2, volume: -40, tailDrop: -10, rate: 7),
                .init(pitch: 150, pitchRange: 6, volume: -40, tailDrop: -2, rate: 7),
                .init(pitch: 150, pitchRange: 6, volume: -40, tailDrop: -2, rate: 12),
            ],
            pitchContour: [], volumeContour: [], issues: []
        )
        let sentences = [
            Sentence(start: 0, end: 5, text: "えっと平らな文。"), Sentence(start: 8, end: 12, text: "普通の文。"),
            Sentence(start: 40, end: 44, text: "早口の文。"),
        ]
        let kinds = analysis.findings(sentences).map(\.kind)
        // 時刻順。平らな文は0秒から、フィラーは1秒。
        #expect(kinds == [.monotone, .weakEnding, .filler, .longPause, .silence, .fast])
        #expect(analysis.spokenPauses.count == 2)
        #expect(abs(analysis.fillersPerMinute - 1) < 0.001)
    }
}

@MainActor
struct AnalysisStoreTests {
    @Test func 文字起こしをやり直すと分析も作り直す() throws {
        let paths = try makePaths()
        let store = try makeStore(paths)
        let recording = try store.createForRecording()
        recording.state = .ready
        try store.saveTranscript(Transcript(locale: "ja-JP", sentences: [sentence("はい。")]), to: recording)
        #expect(recording.needsAnalysis)
        let analysis = SpeakingAnalyzer.analyze(VoiceFrames(level: [], pitch: []), sentences: [])
        try store.saveAnalysis(analysis, to: recording)
        #expect(recording.analysis == analysis)
        #expect(!recording.needsAnalysis)
        try store.saveTranscript(Transcript(locale: "ja-JP", sentences: [sentence("いいえ。")]), to: recording)
        #expect(recording.analysis == nil)
        #expect(recording.needsAnalysis)
    }

    @Test func 時刻を足しても章はそのまま() throws {
        let paths = try makePaths()
        let store = try makeStore(paths)
        let recording = try store.createForRecording()
        recording.state = .ready
        try store.saveTranscript(
            Transcript(locale: "ja-JP", sentences: [Sentence(start: 0, end: 1, text: "はい。")]), to: recording
        )
        try store.saveChapters([Chapter(start: 0, title: "始め")], to: recording)
        try store.attachTimes([sentence("はい。")], to: recording)
        #expect(recording.transcript?.sentences[0].times != nil)
        #expect(recording.chapters.map(\.title) == ["始め"])
        // 本文が違えば何もしない。
        try store.attachTimes([sentence("いいえ。")], to: recording)
        #expect(recording.transcript?.sentences[0].text == "はい。")
    }
}

/// 実際の録音で分析する確認。普段は動かさない。
/// TEST_RUNNER_MR_SAMPLE=<音声ファイル> xcodebuild … test -only-testing:MicRepsTests/RealSpeakingTests
struct RealSpeakingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MR_SAMPLE"] != nil))
    func 実際に分析する() async throws {
        let url = URL(filePath: ProcessInfo.processInfo.environment["MR_SAMPLE"]!)
        let started = Date()
        let pieces = try await AppleTranscriber().transcribe(url, locale: Locale(identifier: "ja-JP")) { _ in }
        let sentences = SentenceBuilder.build(pieces)
        let transcribed = Date()
        let analysis = try await SpeakingAnalyzer.analyze(url, sentences: sentences)
        print("SPEAK transcribe=\(transcribed.timeIntervalSince(started))s analyze=\(Date().timeIntervalSince(transcribed))s")
        print("SPEAK speaking=\(analysis.speakingTime) fillers=\(analysis.fillers.count) perMin=\(analysis.fillersPerMinute)")
        print("SPEAK pauses=\(analysis.spokenPauses.count) rate=\(analysis.medianRate ?? 0) pitch=\(analysis.medianPitch ?? 0) range=\(analysis.medianPitchRange ?? 0) spread=\(analysis.volumeSpread ?? 0)")
        print("SPEAK habits", analysis.habits.map { "\($0.word)=\($0.count)" })
        for finding in analysis.findings(sentences) where finding.time < 180 {
            print("SPEAK", TimeText.short(finding.time), finding.kind.title, finding.detail)
        }
        let data = try JSONEncoder().encode(analysis)
        print("SPEAK json=\(data.count)bytes")
        #expect(!analysis.fillers.isEmpty)
    }
}
