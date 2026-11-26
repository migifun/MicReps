import Foundation
import Testing
@testable import MicReps

private func sentence(_ text: String, from start: Double = 0, seconds: Double? = nil) -> Sentence {
    Sentence(start: start, end: start + (seconds ?? Double(text.count) * 0.1), text: text)
}

/// 同じ語が繰り返されない(言い直しに数えられない)n文字の文字列。
private func varied(_ count: Int) -> String {
    String((0..<count).map { Character(UnicodeScalar(0x4E00 + $0 * 37)!) })
}

struct SpokenSentenceTests {
    @Test func 句点までをまとめフィラーを除く() {
        let sentences = [sentence("えっと、今日は", from: 0), sentence("話します。", from: 2), sentence("次です。", from: 5)]
        let fillers = FillerDetector.fillers(in: sentences)
        let spoken = SpokenSentence.build(sentences, fillers: fillers)
        #expect(spoken.map(\.text) == ["今日は話します。", "次です。"])
        #expect(spoken[0].first == 0 && spoken[0].last == 1)
        #expect(spoken[0].start == 0 && abs(spoken[0].end - 2.5) < 0.001)
        #expect(spoken[0].length == 7)
    }

    @Test func 句点で終わらない最後の文も含める() {
        let spoken = SpokenSentence.build([sentence("はい。"), sentence("途中で", from: 1)], fillers: [])
        #expect(spoken.map(\.text) == ["はい。", "途中で"])
    }
}

struct SentenceRuleTests {
    private func kinds(_ texts: [String], seconds: Double? = nil) -> [SpeakingAnalysis.SentenceIssue.Kind] {
        let sentences = texts.enumerated().map { sentence($1, from: Double($0) * 30, seconds: seconds) }
        return SentenceRules.issues(SpokenSentence.build(sentences, fillers: [])).map(\.kind)
    }

    @Test func 長い文() {
        #expect(kinds([varied(79) + "。"]).isEmpty)
        #expect(kinds([varied(80) + "。"]) == [.long])
        // 短くても、話すのに20秒以上かかった文。
        #expect(kinds(["短い文です。"], seconds: 21) == [.long])
        let detail = SentenceRules.issues(SpokenSentence.build(
            [sentence(String(repeating: "あ、", count: 60) + "。", seconds: 25)], fillers: []
        ))[0].detail
        #expect(detail == "60字・25秒・読点60")
        #expect(SentenceRules.issues(SpokenSentence.build([sentence(varied(120) + "。")], fillers: []))[0].detail.hasPrefix("とても長い 120字"))
    }

    @Test func 飾る言葉が続く文() {
        #expect(SentenceRules.modifiers(in: "とても便利な、使いやすい、小さくて軽いアプリです。") == 2)
        #expect(SentenceRules.modifiers(in: "私が作り始めた、とても便利な、使いやすい、軽いアプリです。") == 3)
        #expect(SentenceRules.modifiers(in: "外で遊ぶものなのか、家で過ごすのか、決めてみないと分からない。") == 0)
        #expect(kinds(["私が作り始めた、とても便利な、使いやすい、軽いアプリです。"]) == [.modifiers])
    }

    @Test func 言い直し() {
        #expect(SentenceRules.restarts(in: "資料の中資料たちの中に答えがなかった。") == ["資料の中資料"])
        #expect(SentenceRules.restarts(in: "結果は時間によって時間によって変わる。") == ["時間によって時間によって"])
        // 読点を挟む繰り返しや、口癖の繰り返しは数えない。
        #expect(SentenceRules.restarts(in: "資料の中で、資料として使う。").isEmpty)
        #expect(SentenceRules.restarts(in: "実際作って実際試した。").isEmpty)
        #expect(SentenceRules.restarts(in: "アプリやスマホアプリとして使う。").isEmpty)
    }
}

struct SentenceReviewBuilderTests {
    private let spoken = SpokenSentence.build([
        sentence("今日は録音アプリの紹介をします。", from: 0),
        sentence("ちなみに昨日の雑談ですがラーメンがおいしかった。", from: 5),
        sentence("短い。", from: 10),
        sentence(varied(90) + "。", from: 12),
    ], fillers: [])

    private var issues: [SpeakingAnalysis.SentenceIssue] { SentenceRules.issues(spoken) }

    @Test func 脱線と言い直しの例を作る() async throws {
        let reviewer = FakeReviewer()
        let review = try await SentenceReviewBuilder.build(
            spoken, issues: issues, chapters: [Chapter(start: 0, title: "アプリの紹介")], reviewer: reviewer
        )
        #expect(review.offTopic == [1])
        #expect(review.rewrites.map(\.sentence) == [3])
        #expect(review.rewrites[0].text.hasPrefix("例:"))
        // 短い文には脱線かを聞かない。
        #expect(reviewer.roleCalls == 3)
        #expect(review.skipped == 0)
    }

    @Test func 章が無ければ脱線は判定しない() async throws {
        let reviewer = FakeReviewer()
        let review = try await SentenceReviewBuilder.build(spoken, issues: issues, chapters: [], reviewer: reviewer)
        #expect(reviewer.roleCalls == 0)
        #expect(review.offTopic.isEmpty)
        #expect(review.rewrites.count == 1)
    }

    @Test func 答えない文は飛ばして数える() async throws {
        let reviewer = FakeReviewer()
        reviewer.refused = ["ラーメン"]
        let review = try await SentenceReviewBuilder.build(
            spoken, issues: issues, chapters: [Chapter(start: 0, title: "紹介")], reviewer: reviewer
        )
        #expect(review.skipped == 1)
        #expect(review.offTopic.isEmpty)
    }

    @Test func どれにも答えなければ失敗にする() async {
        let reviewer = FakeReviewer()
        reviewer.refused = ["。"]
        await #expect(throws: ReviewError.refused) {
            try await SentenceReviewBuilder.build(
                spoken, issues: issues, chapters: [Chapter(start: 0, title: "紹介")], reviewer: reviewer
            )
        }
    }

    @Test func 指摘の一覧に言い直しの例と脱線が入る() async throws {
        let review = SentenceReview(offTopic: [1], rewrites: [.init(sentence: 3, text: "短くした文。")], skipped: 0)
        let analysis = SpeakingAnalysis(
            duration: 30, speakingTime: 30, noiseFloor: -70, silenceThreshold: -60, pauses: [], fillers: [],
            habits: [], sentences: [], pitchContour: [], volumeContour: [], issues: issues
        )
        let sentences = [
            sentence("今日は録音アプリの紹介をします。", from: 0),
            sentence("ちなみに昨日の雑談ですがラーメンがおいしかった。", from: 5),
            sentence("短い。", from: 10), sentence(varied(90) + "。", from: 12),
        ]
        let findings = analysis.findings(sentences, review: review)
        #expect(findings.map(\.kind) == [.offTopic, .longSentence])
        #expect(findings[1].rewrite == "短くした文。")
    }
}

@MainActor
struct ReviewStoreTests {
    @Test func 分析をやり直すと見直しも作り直す_章ができるまで待つ() throws {
        let paths = try makePaths()
        let store = try makeStore(paths)
        let recording = try store.createForRecording()
        recording.state = .ready
        try store.saveTranscript(Transcript(locale: "ja-JP", sentences: [sentence("はい。")]), to: recording)
        let analysis = SpeakingAnalyzer.analyze(VoiceFrames(level: [], pitch: []), sentences: [])
        try store.saveAnalysis(analysis, to: recording)
        #expect(!recording.needsReview)   // 章がまだ
        try store.markChapters(recording, .tooShort)
        #expect(recording.needsReview)
        try store.saveReview(SentenceReview(offTopic: [], rewrites: [], skipped: 0), to: recording)
        #expect(!recording.needsReview)
        #expect(recording.review != nil)
        try store.saveAnalysis(analysis, to: recording)
        #expect(recording.review == nil)
        #expect(recording.needsReview)
    }
}

/// 実際の録音とAIで文を見直す確認。普段は動かさない。
/// TEST_RUNNER_MR_SAMPLE=<音声ファイル> xcodebuild … test -only-testing:MicRepsTests/RealReviewTests
struct RealReviewTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MR_SAMPLE"] != nil))
    func 実際に見直す() async throws {
        let url = URL(filePath: ProcessInfo.processInfo.environment["MR_SAMPLE"]!)
        let locale = Locale(identifier: "ja-JP")
        let pieces = try await AppleTranscriber().transcribe(url, locale: locale) { _ in }
        let sentences = SentenceBuilder.build(pieces)
        let analysis = try await SpeakingAnalyzer.analyze(url, sentences: sentences)
        let chapters = try await ChapterBuilder.build(sentences, locale: locale, generator: AppleChapterGenerator()) { _ in }
        let spoken = SpokenSentence.build(sentences, fillers: analysis.fillers)
        let started = Date()
        let review = try await SentenceReviewBuilder.build(
            spoken, issues: analysis.issues, chapters: chapters, reviewer: AppleSentenceReviewer()
        )
        print("REVIEW took=\(Date().timeIntervalSince(started))s spoken=\(spoken.count) skipped=\(review.skipped)")
        print("REVIEW chapters", chapters.map(\.title))
        for finding in analysis.findings(sentences, review: review)
        where [.longSentence, .modifiers, .restart, .offTopic].contains(finding.kind) {
            print("REVIEW", TimeText.short(finding.time), finding.kind.title, finding.detail)
            if let rewrite = finding.rewrite { print("REVIEW   →", rewrite) }
        }
    }
}
