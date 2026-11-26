import Foundation
import Testing
@testable import MicReps

private let ja = Locale(identifier: "ja-JP")

/// 1文5秒の文。話題ごとに文面が変わる。
private func speech(_ topics: [(String, Int)]) -> [Sentence] {
    var result: [Sentence] = []
    for (topic, count) in topics {
        for i in 0..<count {
            let start = Double(result.count) * 5
            let text = i == 0 ? "続いて\(topic)について話します。" : "\(topic)の詳細その\(i)を説明しています。"
            result.append(Sentence(start: start, end: start + 5, text: text))
        }
    }
    return result
}

/// 話題の最初の文を正しく書き写すAI。区間の先頭にも必ず章を付ける(実際のAIの癖)。
private func honest(_ window: [String]) -> [ChapterProposal] {
    window.enumerated().compactMap { i, text in
        guard text.hasPrefix("続いて") || i == 0 else { return nil }
        let topic = text.replacingOccurrences(of: "続いて", with: "").prefix { $0 != "に" && $0 != "の" }
        return ChapterProposal(title: String(topic), firstSentence: text)
    }
}

@MainActor
struct ChapterBuilderTests {
    let generator = FakeGenerator()

    private func build(_ sentences: [Sentence]) async throws -> [Chapter] {
        try await ChapterBuilder.build(sentences, locale: ja, generator: generator, onProgress: { _ in })
    }

    @Test func 長い録音でも区間の境目で章が切れたり重なったりしない() async throws {
        let topics = ["売上", "採用", "移転", "安全", "健康", "宴会", "製品", "広報"].map { ($0, 13) }
        generator.answer = honest
        let chapters = try await build(speech(topics))
        #expect(chapters.map(\.title) == topics.map(\.0))
        #expect(chapters.map(\.start) == (0..<8).map { Double($0) * 65 })
    }

    @Test func 一つの話題が区間より長くても分かれない() async throws {
        generator.answer = honest
        let chapters = try await build(speech([("売上", 100), ("採用", 20)]))
        #expect(chapters.map(\.title) == ["売上", "採用"])
        #expect(chapters[1].start == 500)
    }

    @Test func 答えが六つの上限で切れても残りを見に行く() async throws {
        let topics = ["売上", "採用", "移転", "安全", "健康", "宴会", "製品", "広報"].map { ($0, 4) }
        generator.answer = { Array(honest($0).prefix(6)) }
        let chapters = try await build(speech(topics))
        #expect(chapters.map(\.title) == topics.map(\.0))
    }

    @Test func 逆順の答えは無関係な似た文に当てず捨てる() {
        let texts = speech([("売上", 10), ("採用", 10)]).map(\.text)
        let found = ChapterBuilder.locate([
            ChapterProposal(title: "後半", firstSentence: texts[10]), ChapterProposal(title: "逆順", firstSentence: texts[3]),
        ], in: texts, range: 0..<20)
        #expect(found.map(\.title) == ["後半"])
    }

    @Test func 範囲外の行番号は捨てる() {
        let found = ChapterBuilder.locate([
            ChapterProposal(title: "前", line: 9), ChapterProposal(title: "中", line: 12),
            ChapterProposal(title: "後", line: 20), ChapterProposal(title: "  ", line: 13),
        ], in: Array(repeating: "あ", count: 30), range: 10..<20)
        #expect(found == [.init(index: 12, title: "中")])
    }

    @Test func 二つ以上の答えが一致した所だけを選ぶ() {
        typealias C = ChapterBuilder.Candidate
        let result = ChapterBuilder.vote([
            [C(index: 0, title: "頭"), C(index: 20, title: "引用の見出し"), C(index: 33, title: "単独1")],
            [C(index: 0, title: "頭"), C(index: 21, title: "番号の見出し")],
            [C(index: 1, title: "頭"), C(index: 21, title: "番号の見出し"), C(index: 50, title: "単独2")],
        ], count: 60)
        #expect(result == [C(index: 0, title: "頭"), C(index: 20, title: "引用の見出し")])
        // 答えが1つしか得られなかったときは、それを使う。
        #expect(ChapterBuilder.vote([[C(index: 5, title: "唯一")]], count: 60).count == 1)
        #expect(ChapterBuilder.vote([], count: 60).isEmpty)
        #expect(ChapterBuilder.vote([[], []], count: 0).isEmpty)
    }

    @Test func 本文に無い文の答えは使わない() async throws {
        generator.answer = { window in [
            ChapterProposal(title: "最初", firstSentence: window[0]),
            ChapterProposal(title: "捏造", firstSentence: "まったく関係のない作り話です。"),
            ChapterProposal(title: "後半", firstSentence: window[10]),
        ] }
        let chapters = try await build(speech([("売上", 10), ("採用", 9)]))
        #expect(chapters.map(\.title) == ["最初", "後半"])
    }

    @Test func 少し違う書き写しでも照合できる() {
        let texts = ["今日は晴れです。", "続いて、新製品の開発スケジュールについてです。", "以上です。"]
        let found = ChapterBuilder.locate(
            [ChapterProposal(title: "「新製品」", firstSentence: "続いて新製品の開発スケジュールについて")], in: texts, range: 0..<3
        )
        #expect(found == [.init(index: 1, title: "新製品")])
    }

    @Test func 長すぎると区間を半分にしてやり直す() async throws {
        generator.answer = { window in
            if window.count > 10 { throw ChapterError.tooLong }
            return honest(window)
        }
        let chapters = try await build(speech([("売上", 20), ("採用", 20)]))
        #expect(chapters.map(\.title) == ["売上", "採用"])
        #expect(generator.windows.allSatisfy { $0.count <= 45 })
    }

    @Test func 断られた区間だけ飛ばす() async throws {
        generator.answer = { window in
            if window[0].contains("売上") { throw ChapterError.refused }
            return honest(window)
        }
        let chapters = try await build(speech([("売上", 35), ("採用", 20), ("移転", 20)]))
        #expect(chapters.first?.title == ChapterBuilder.openingTitle)
        #expect(chapters.map(\.title).contains("移転"))
    }

    @Test func すべて断られたり何も見つからなければエラー() async {
        generator.answer = { _ in throw ChapterError.refused }
        await #expect(throws: ChapterError.refused) { try await build(speech([("売上", 40)])) }
        generator.answer = { _ in [] }
        await #expect(throws: ChapterError.nothingFound) { try await build(speech([("売上", 40)])) }
    }

    @Test func その他の失敗はそのまま伝わる() async {
        generator.answer = { _ in throw CocoaError(.fileReadUnknown) }
        await #expect(throws: CocoaError.self) { try await build(speech([("売上", 40)])) }
    }

    @Test func 先頭は必ず0秒からになる() async throws {
        generator.answer = { [ChapterProposal(title: "本題", firstSentence: $0[8])] }
        let late = try await build(speech([("売上", 30)]))
        #expect(late.map(\.title) == [ChapterBuilder.openingTitle, "本題"])
        #expect(late[0].start == 0)
        generator.answer = { [ChapterProposal(title: "本題", firstSentence: $0[2])] }
        let early = try await build(speech([("売上", 30)]))
        #expect(early.map(\.title) == ["本題"])
        #expect(early[0].start == 0)
    }

    @Test func 質問で始まる話題は質問から始まる() async throws {
        var sentences = speech([("売上", 30)])
        sentences[14].text = "ところで採用はどうなっていますか。"
        sentences[15].text = "現在は十五名の応募があります。"
        generator.answer = { window in
            [ChapterProposal(title: "売上", firstSentence: window[0])]
                + (window.firstIndex { $0.hasPrefix("現在は") }.map { [ChapterProposal(title: "採用", firstSentence: window[$0])] } ?? [])
        }
        #expect(try await build(sentences).map(\.start) == [0, 70])
    }

    @Test func 話題を切り出す文に章の頭を合わせる() {
        typealias C = ChapterBuilder.Candidate
        let texts = ["始めます。", "売上の話です。", "次は採用ですね。", "応募は九名です。", "順調です。", "以上です。"]
        func snapped(_ i: Int) -> Int { ChapterBuilder.snapToOpenings([C(index: i, title: "x")], texts: texts)[0].index }
        #expect([0, 1, 2, 3, 4, 5].map(snapped) == [0, 2, 2, 2, 2, 5])
    }

    @Test func 短すぎる章と似た見出しはまとめる() {
        let candidates = [(0, "話0"), (1, "話1"), (2, "話2"), (10, "採用"), (11, "雑談"), (20, "採用の状況")]
            .map { ChapterBuilder.Candidate(index: $0.0, title: $0.1) }
        let chapters = ChapterBuilder.finish(candidates, sentences: speech([("売上", 30)]))
        #expect(chapters.map(\.title) == ["話0", "採用"])
        #expect(chapters.map(\.start) == [0, 50])
    }

    @Test func 章が多すぎるときは短いものからまとめる() {
        let chapters = (0..<40).map { Chapter(start: Double($0) * 60, title: "\($0)") }
        let limited = ChapterBuilder.limit(chapters, end: 2400)
        #expect(limited.count == 26)
        #expect(limited[0].start == 0)
        #expect(zip(limited, limited.dropFirst()).allSatisfy { $0.start < $1.start })
    }

    @Test func 区間は文数と文字数の両方で区切られ必ず進む() {
        #expect(ChapterBuilder.windowEnd(Array(repeating: "あ", count: 100), from: 10, limit: 35) == 45)
        let long = Array(repeating: String(repeating: "あ", count: 1000), count: 10)
        #expect(ChapterBuilder.windowEnd(long, from: 0, limit: 35) == 2)
        #expect(ChapterBuilder.windowEnd([String(repeating: "あ", count: 9000)], from: 0, limit: 35) == 1)
    }

    @Test func 短い文字起こしの判定() {
        #expect(ChapterBuilder.isTooShort([]))
        #expect(ChapterBuilder.isTooShort(speech([("売上", 4)])))
        #expect(!ChapterBuilder.isTooShort(speech([("売上", 12)])))
    }
}

struct ChapterTests {
    private let chapters = [Chapter(start: 0, title: "a"), Chapter(start: 30, title: "b"), Chapter(start: 60, title: "c")]

    @Test func 現在の章() {
        #expect(Chapter.index(at: 0, in: chapters) == 0)
        #expect(Chapter.index(at: 29.9, in: chapters) == 0)
        #expect(Chapter.index(at: 30, in: chapters) == 1)
        #expect(Chapter.index(at: 999, in: chapters) == 2)
        #expect(Chapter.index(at: 5, in: []) == nil)
        #expect(Chapter.index(at: 5, in: [Chapter(start: 10, title: "x")]) == nil)
    }

    @Test func 前後の章への移動() {
        #expect(Chapter.nextStart(from: 0, in: chapters) == 30)
        #expect(Chapter.nextStart(from: 60, in: chapters) == nil)
        #expect(Chapter.previousStart(from: 45, in: chapters) == 30)
        #expect(Chapter.previousStart(from: 31, in: chapters) == 0)
        #expect(Chapter.previousStart(from: 1, in: chapters) == 0)
        #expect(Chapter.previousStart(from: 1, in: []) == nil)
    }

    @Test func 見出しつきコピー() {
        let transcript = Transcript(locale: "ja-JP", sentences: [
            Sentence(start: 0.5, end: 2, text: "一。"), Sentence(start: 5, end: 8, text: "二。"),
            Sentence(start: 30, end: 40, text: "三。"),
        ])
        #expect(transcript.text(.chaptered, chapters: Array(chapters.prefix(2)))
            == "■ 0:00 a\n一。\n二。\n\n■ 0:30 b\n三。")
        #expect(transcript.text(.chaptered) == "一。\n二。\n三。")
        #expect(transcript.text(.chaptered, chapters: [Chapter(start: 30, title: "b")])
            == "一。\n二。\n\n■ 0:30 b\n三。")
    }
}

/// 実際のAIを使う確認。普段は動かさない。
/// 「#見出し」で話題を区切った原稿を置いたフォルダを TEST_RUNNER_MR_SCRIPTS で渡す。
@MainActor
struct RealChapterTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MR_SCRIPTS"] != nil))
    func 実際にチャプターを作る() async throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["MR_SCRIPTS"]!)
        var total = (expected: 0, made: 0, recalled: 0, precise: 0, exact: 0)
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            var sentences: [Sentence] = []
            var truth: [Double] = []
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                if line.hasPrefix("#") { truth.append(sentences.last?.end ?? 0); continue }
                let start = sentences.last?.end ?? 0
                // 1秒に5文字で話したとする(確認に使った合成音声の実測)。
                sentences.append(Sentence(start: start, end: start + Double(line.count) / 5, text: String(line)))
            }
            let began = Date()
            let chapters = try await ChapterBuilder.build(
                sentences, locale: ja, generator: AppleChapterGenerator(), onProgress: { _ in }
            )
            func sentence(_ time: Double) -> Int { Transcript.index(at: time, in: sentences) ?? 0 }
            let made = chapters.map { sentence($0.start) }
            let expected = truth.map(sentence)
            total.expected += expected.count
            total.made += made.count
            total.exact += expected.count { made.contains($0) }
            total.recalled += expected.count { e in made.contains { abs($0 - e) <= 1 } }
            total.precise += made.count { m in expected.contains { abs($0 - m) <= 1 } }
            print("CHAP", file.lastPathComponent, "expected", expected.count, "made", made.count,
                  "took", Int(Date().timeIntervalSince(began)), "s of", Int(sentences.last!.end), "s")
            print("CHAP    recalled", expected.count { e in made.contains { abs($0 - e) <= 1 } })
            for chapter in chapters { print("CHAP   ", TimeText.short(chapter.start), chapter.title) }
        }
        print("CHAP TOTAL", total)
        // 1文以内の一致。見つけた章の正しさを優先している。
        #expect(total.precise * 4 >= total.made * 3)
        // 話題が章数の上限より多い原稿では、上限の範囲で見る。
        #expect(total.recalled * 2 >= min(total.expected, total.made))
    }
}
