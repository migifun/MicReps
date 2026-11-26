import Foundation
import Testing
@testable import MicReps

private func analysis(
    speaking: Double = 600, fillers: [SpeakingAnalysis.Filler] = [], pauses: [SpeakingAnalysis.Pause] = [],
    issues: [SpeakingAnalysis.SentenceIssue] = [], voices: [SpeakingAnalysis.SentenceVoice] = [],
    habits: [SpeakingAnalysis.Habit] = []
) -> SpeakingAnalysis {
    SpeakingAnalysis(
        duration: speaking, speakingTime: speaking, noiseFloor: -70, silenceThreshold: -60, pauses: pauses,
        fillers: fillers, habits: habits, sentences: voices, pitchContour: [], volumeContour: [], issues: issues
    )
}

struct MetricsTests {
    private func metrics(_ day: Int, _ fillers: Double, pitch: Double? = nil) -> SpeakingMetrics {
        var values: [SpeakingMetrics.Metric: Double] = [.fillers: fillers]
        values[.pitchRange] = pitch
        return SpeakingMetrics(title: "\(day)", createdAt: Date(timeIntervalSince1970: Double(day) * 86400),
                               duration: 600, values: values)
    }

    @Test func ふだんの値は最新を除いた中央値() {
        let history = [metrics(1, 3), metrics(2, 5), metrics(3, 4), metrics(4, 1)]
        #expect(SpeakingMetrics.baseline(.fillers, in: history) == 4)
        #expect(SpeakingMetrics.baseline(.fillers, in: [metrics(1, 3), metrics(2, 5), metrics(3, 1)]) == 4)
        #expect(SpeakingMetrics.baseline(.fillers, in: [metrics(1, 3)]) == nil)
    }

    @Test func 良くなったかは項目の向きで決まる() {
        #expect(SpeakingMetrics.change(.fillers, latest: 2, baseline: 3) == .better)
        #expect(SpeakingMetrics.change(.fillers, latest: 4, baseline: 3) == .worse)
        #expect(SpeakingMetrics.change(.pitchRange, latest: 7, baseline: 6) == .better)
        #expect(SpeakingMetrics.change(.rate, latest: 8, baseline: 6) == .neutral)
        #expect(SpeakingMetrics.change(.fillers, latest: 3.05, baseline: 3) == .same)
    }

    @MainActor
    @Test func 録音の分析から数値にする() throws {
        let paths = try makePaths()
        let store = try makeStore(paths)
        let recording = try store.createForRecording()
        recording.state = .ready
        try store.saveTranscript(Transcript(locale: "ja-JP", sentences: [Sentence(start: 0, end: 1, text: "はい。")]), to: recording)
        let fillers = (0..<20).map { _ in SpeakingAnalysis.Filler(sentence: 0, offset: 0, length: 1, time: 0, word: "で", isCertain: false) }
        try store.saveAnalysis(analysis(
            speaking: 600, fillers: fillers,
            issues: [.init(kind: .long, sentence: 0, time: 0, detail: ""), .init(kind: .restart, sentence: 0, time: 0, detail: "")],
            voices: [.init(pitch: 150, pitchRange: 6, volume: -40, tailDrop: 0, rate: 7)],
            habits: [.init(word: "実際", count: 30)]
        ), to: recording)
        let metrics = try #require(SpeakingMetrics(recording))
        #expect(metrics.values[.fillers] == 2)
        #expect(metrics.values[.longSentences] == 1)
        #expect(metrics.values[.restarts] == 1)
        #expect(metrics.values[.rate] == 7)
        #expect(metrics.values[.volumeSpread] == nil)   // 文が3つ未満
        #expect(metrics.habits["実際"] == 3)
        #expect(SpeakingMetrics.topHabits([metrics]) == ["実際"])
    }

    @MainActor
    @Test func 短すぎる録音は数値にしない() throws {
        let paths = try makePaths()
        let store = try makeStore(paths)
        let recording = try store.createForRecording()
        recording.state = .ready
        try store.saveTranscript(Transcript(locale: "ja-JP", sentences: [Sentence(start: 0, end: 1, text: "はい。")]), to: recording)
        try store.saveAnalysis(analysis(speaking: 20), to: recording)
        #expect(SpeakingMetrics(recording) == nil)
    }
}

struct TranscriptMarksTests {
    private let sentences = [
        Sentence(start: 0, end: 4, text: "えっと、今日は話します。", times: (0..<12).map { Double($0) * 0.3 }),
        Sentence(start: 10, end: 14, text: "資料の中資料たちの中です。", times: (0..<13).map { 10 + Double($0) * 0.3 }),
    ]

    @Test func 章とフィラーと言い直しと間を文に付ける() {
        let result = TranscriptMarks.build(
            sentences,
            analysis: analysis(
                fillers: [.init(sentence: 0, offset: 0, length: 3, time: 0, word: "えっと", isCertain: true)],
                pauses: [.init(start: 1.0, length: 1.2), .init(start: 4.5, length: 5), .init(start: 12, length: 0.5)],
                issues: [
                    .init(kind: .restart, sentence: 1, time: 10, detail: "「資料の中資料」"),
                    .init(kind: .long, sentence: 1, time: 10, detail: "90字・20秒・読点0"),
                ]
            ),
            review: SentenceReview(offTopic: [], rewrites: [.init(sentence: 1, text: "言い直し。")], skipped: 0),
            chapters: [Chapter(start: 0, title: "始め"), Chapter(start: 9, title: "次")]
        )
        #expect(result[0].chapter == "始め")
        #expect(result[1].chapter == "次")
        #expect(result[0].fillers == [.init(offset: 0, length: 3)])
        // 文の途中の間は、近くの読点の後ろへ。
        #expect(result[0].pauses == [.init(offset: 4, length: 1.2)])
        // 文と文の間の長い間は、前の文のあと。1秒未満の間は出さない。
        #expect(result[0].pauseAfter == 5)
        #expect(result[1].pauses.isEmpty)
        #expect(result[1].restarts == [.init(offset: 0, length: 6)])
        #expect(result[1].badges.map(\.kind) == [.longSentence])
        #expect(result[1].badges[0].rewrite == "言い直し。")
    }

    @Test func 分析が無くても章は付ける() {
        let result = TranscriptMarks.build(sentences, analysis: nil, review: nil, chapters: [Chapter(start: 9, title: "次")])
        #expect(result.map(\.chapter) == [nil, "次"])
    }

    @Test func 話し終えた文字数() {
        let sentence = sentences[0]
        #expect(TranscriptMarks.playedCount(in: sentence, at: -1) == 0)
        #expect(TranscriptMarks.playedCount(in: sentence, at: 0.65) == 3)
        #expect(TranscriptMarks.playedCount(in: sentence, at: 9) == 12)
    }

    @Test func 間は近くの区切りへずらす() {
        #expect(TranscriptMarks.snapped(6, in: "あいう、えおかきくけこ") == 4)
        #expect(TranscriptMarks.snapped(3, in: "あいうえおかきくけこさしすせそ") == 3)
    }
}

struct SpeakingReportTests {
    @Test func まとめと指摘と言い直しの例を書く() {
        let sentences = [Sentence(start: 0, end: 30, text: "長い文です。")]
        let text = Exporter.speakingReport(
            title: "練習", createdAt: Date(timeIntervalSince1970: 0), duration: 65, sentences: sentences,
            analysis: analysis(
                speaking: 60,
                fillers: [.init(sentence: 0, offset: 0, length: 1, time: 1, word: "で", isCertain: false)],
                issues: [.init(kind: .long, sentence: 0, time: 0, detail: "90字・30秒・読点2")],
                habits: [.init(word: "実際", count: 4)]
            ),
            review: SentenceReview(offTopic: [], rewrites: [.init(sentence: 0, text: "短く。")], skipped: 0)
        )
        #expect(text.hasPrefix("# 練習 話し方の分析\n"))
        #expect(text.contains("| フィラー | 1回(1分に1.0) |"))
        #expect(text.contains("- 「実際」4回"))
        #expect(text.contains("- 0:00 長い文: 90字・30秒・読点2\n    - 言い直しの例(AI): 短く。"))
        #expect(text.contains("- 0:01 フィラー: 「で」(推定)"))
    }
}
