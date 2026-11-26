import AppKit
import AVFAudio
import Foundation
import SwiftData
import Testing
@testable import MicReps

/// 1文字 0.1 秒の断片にする。
private func pieces(_ text: String, from start: Double = 0) -> [TimedText] {
    text.enumerated().map {
        TimedText(text: String($1), start: start + Double($0) * 0.1, end: start + Double($0 + 1) * 0.1)
    }
}

struct SentenceBuilderTests {
    private func texts(_ pieces: [TimedText]) -> [String] { SentenceBuilder.build(pieces).map(\.text) }

    @Test func 句点や疑問符で切る() {
        #expect(texts(pieces("始めます。いいですか？はい！次です")) == ["始めます。", "いいですか？", "はい！", "次です"])
    }

    @Test func 時刻は最初と最後の文字のもの() {
        let result = SentenceBuilder.build(pieces("はい。次。", from: 2))
        #expect(abs(result[0].start - 2) < 0.001)
        #expect(abs(result[0].end - 2.3) < 0.001)
        #expect(abs(result[1].start - 2.3) < 0.001)
    }

    @Test func 断片の途中に句点があっても切る() {
        let result = SentenceBuilder.build([TimedText(text: "終わり。次は", start: 0, end: 6)])
        #expect(result.map(\.text) == ["終わり。", "次は"])
        #expect(abs(result[1].start - 4) < 0.001)
    }

    @Test func 閉じかっこや重なった記号は前の文に含める() {
        #expect(texts(pieces("「行こう。」と言った。本当？！そう。")) == ["「行こう。」", "と言った。", "本当？！", "そう。"])
    }

    @Test func 長い間で切るが短い文の短い間では切らない() {
        #expect(texts(pieces("えーと") + pieces("次の話", from: 4)) == ["えーと", "次の話"])
        #expect(texts(pieces("えーと") + pieces("次の話", from: 1.5)) == ["えーと次の話"])
        let long = String(repeating: "あ", count: 45)
        #expect(texts(pieces(long) + pieces("次", from: 6)).count == 2)
    }

    @Test func 句読点が無くても長くなりすぎない() {
        let result = texts(pieces(String(repeating: "あ", count: 400)))
        #expect(result.allSatisfy { $0.count <= SentenceBuilder.hardLimit })
        #expect(result.joined().count == 400)
        let comma = texts(pieces(String(repeating: "あ", count: 85) + "、" + String(repeating: "い", count: 20)))
        #expect(comma.count == 2)
        #expect(comma[0].hasSuffix("、"))
    }

    @Test func 日本語のまわりの空白だけを取る() {
        #expect(SentenceBuilder.tidy(" 全体の 4割を iPhone 15 で測る ") == "全体の4割をiPhone 15で測る")
        #expect(SentenceBuilder.tidy("Hello  big world") == "Hello big world")
    }

    @Test func 英文はピリオドで切り小数では切らない() {
        #expect(texts(pieces("It is 3.5 now. Next one. ")) == ["It is 3.5 now.", "Next one."])
    }

    @Test func 時刻の無い断片や逆行した時刻でも順序が保たれる() {
        let result = SentenceBuilder.build([
            TimedText(text: "一。", start: 1, end: 2), TimedText(text: "二。", start: nil, end: nil),
            TimedText(text: "三。", start: 0.5, end: 0.8), TimedText(text: "四。", start: 5, end: 6),
        ])
        #expect(result.map(\.text) == ["一。", "二。", "三。", "四。"])
        #expect(zip(result, result.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(result.allSatisfy { $0.start <= $0.end })
    }

    @Test func 空や空白だけなら文は無い() {
        #expect(texts([]).isEmpty)
        #expect(texts(pieces("   ")).isEmpty)
        #expect(texts([TimedText(text: "", start: 0, end: 1)]).isEmpty)
    }

    @Test func 文字は一つも失われない() {
        let source = "それでは、始めます。「はい。」まず売上ですが、12%増でした！次は？"
        #expect(texts(pieces(source)).joined() == source)
    }
}

struct TranscriptTests {
    private let sentences = [
        Sentence(start: 1, end: 2, text: "一。"), Sentence(start: 5, end: 8, text: "二。"),
        Sentence(start: 70, end: 72, text: "三。"),
    ]

    @Test func 時刻から文を探す() {
        #expect(Transcript.index(at: 0, in: sentences) == nil)
        #expect(Transcript.index(at: 1, in: sentences) == 0)
        #expect(Transcript.index(at: 3, in: sentences) == 0)
        #expect(Transcript.index(at: 4.99, in: sentences) == 1)
        #expect(Transcript.index(at: 999, in: sentences) == 2)
        #expect(Transcript.index(at: 1, in: []) == nil)
    }

    @Test func コピーの書式() {
        let transcript = Transcript(locale: "ja-JP", sentences: sentences)
        #expect(transcript.text(.plain) == "一。\n二。\n三。")
        #expect(transcript.text(.timestamped) == "[0:01] 一。\n[0:05] 二。\n[1:10] 三。")
    }

    @MainActor
    @Test func 本文の位置から文が決まり強調は一か所だけ() throws {
        let view = ClickableTextView(usingTextLayoutManager: true)
        let coordinator = TranscriptTextView.Coordinator()
        coordinator.textView = view
        coordinator.show(sentences + [Sentence(start: 80, end: 81, text: "😀絵文字。")])
        #expect(coordinator.ranges.count == 4)
        #expect(coordinator.sentence(at: 0) == 0)
        #expect(coordinator.sentence(at: 3) == 1)
        #expect(coordinator.sentence(at: (view.string as NSString).length) == 3)
        #expect((view.string as NSString).substring(with: coordinator.ranges[3]) == "😀絵文字。")

        func highlighted() -> [NSRange] {
            var found: [NSRange] = []
            let storage = view.textStorage!
            storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if value != nil { found.append(range) }
            }
            return found
        }
        coordinator.highlight(0)
        coordinator.highlight(1)
        #expect(highlighted() == [coordinator.ranges[1]])
        coordinator.highlight(nil)
        #expect(highlighted().isEmpty)
        coordinator.highlight(99)
        #expect(highlighted().isEmpty)
    }
}

@MainActor
struct ProcessingQueueTests {
    let paths: AppPaths
    let store: RecordingStore
    let transcriber = FakeTranscriber()
    let queue: ProcessingQueue

    init() throws {
        paths = try makePaths()
        store = try makeStore(paths)
        queue = ProcessingQueue(store: store, transcriber: transcriber, generator: FakeGenerator(), reviewer: FakeReviewer()) { Locale(identifier: "ja-JP") }
    }

    private func ready() async throws -> Recording {
        let recording = try store.createForRecording()
        let writer = try CaptureWriter(url: paths.caf(recording.id))
        writer.append(tone(seconds: 0.5))
        writer.close()
        await store.beginFinalizing(recording).value
        return recording
    }

    @Test func 一件ずつ順に行い同じものは二重に入らない() async throws {
        let a = try await ready(), b = try await ready(), c = try await ready()
        for recording in [a, b, c, a] { queue.enqueue(recording.id) }
        await queue.waitUntilIdle()
        #expect(transcriber.calls == [a, b, c].map { paths.m4a($0.id) })
        #expect(transcriber.maxRunning == 1)
        #expect(queue.currentID == nil)
    }

    @Test func 起動時は未処理のものだけを古い順に行う() async throws {
        let a = try await ready(), b = try await ready(), c = try await ready()
        try store.saveTranscript(Transcript(locale: "ja-JP", sentences: []), to: b)
        try queue.enqueuePending()
        await queue.waitUntilIdle()
        #expect(transcriber.calls == [a, c].map { paths.m4a($0.id) })
        #expect(b.transcriptState == .noSpeech)
    }

    @Test func 話し声が無ければそう示す() async throws {
        transcriber.result = .success([])
        let recording = try await ready()
        queue.enqueue(recording.id)
        await queue.waitUntilIdle()
        #expect(recording.transcriptState == .noSpeech)
    }

    @Test func やり直しに失敗しても前の文字起こしは残る() async throws {
        let recording = try await ready()
        queue.enqueue(recording.id)
        await queue.waitUntilIdle()
        transcriber.result = .failure(CocoaError(.fileReadUnknown))
        try queue.retry(recording)
        await queue.waitUntilIdle()
        #expect(recording.transcriptState == .failed)
        #expect(recording.transcript?.sentences.count == 1)
        #expect(recording.transcriptText == "こんにちは。")
    }

    @Test func 一件の失敗で後ろが止まらない() async throws {
        let a = try await ready(), b = try await ready()
        transcriber.result = .failure(CocoaError(.fileReadUnknown))
        queue.enqueue(a.id)
        queue.enqueue(b.id)
        await queue.waitUntilIdle()
        #expect(transcriber.calls.count == 2)
        #expect(b.transcriptState == .failed)
    }

    @Test func データが無ければ案内し導入後にやり直す() async throws {
        transcriber.result = .failure(TranscriberError.needsModel)
        let recording = try await ready()
        queue.enqueue(recording.id)
        await queue.waitUntilIdle()
        #expect(recording.transcriptState == .needsModel)
        #expect(transcriber.installs == 0)
        transcriber.result = .success([TimedText(text: "はい。", start: 0, end: 1)])
        await queue.installModel()
        await queue.waitUntilIdle()
        #expect(transcriber.installs == 1)
        #expect(recording.transcriptState == .done)
    }

    @Test func 文字起こし中に完全削除されても壊れない() async throws {
        let recording = try await ready()
        let store = store
        let id = recording.id
        transcriber.beforeReturn = {
            await MainActor.run {
                guard let row = store.recording(id) else { return }
                try? store.moveToTrash(row)
                try? store.deletePermanently(row)
            }
        }
        queue.enqueue(id)
        await queue.waitUntilIdle()
        #expect(try store.all().isEmpty)
    }

    @Test func 開き直しても文字起こしが残っている() async throws {
        let recording = try await ready()
        queue.enqueue(recording.id)
        await queue.waitUntilIdle()
        let reopened = try makeStore(paths)
        try withExtendedLifetime(reopened) {
            let row = try #require(try reopened.all().first)
            #expect(row.transcript == recording.transcript)
            #expect(row.transcriptState == .done)
        }
    }
}

/// 実際のエンジンを使う確認。普段は動かさない。
/// TEST_RUNNER_MR_SAMPLE=<音声ファイル> xcodebuild … test -only-testing:MicRepsTests/RealTranscriptionTests
struct RealTranscriptionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MR_SAMPLE"] != nil))
    func 実際に文字起こしする() async throws {
        let url = URL(filePath: ProcessInfo.processInfo.environment["MR_SAMPLE"]!)
        let started = Date()
        let pieces = try await AppleTranscriber().transcribe(url, locale: Locale(identifier: "ja-JP")) { _ in }
        let sentences = SentenceBuilder.build(pieces)
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        print("REAL audio=\(Int(duration))s took=\(Date().timeIntervalSince(started))s sentences=\(sentences.count)")
        for sentence in sentences.prefix(30) {
            print("REAL", String(format: "%6.2f-%6.2f", sentence.start, sentence.end), sentence.text)
        }
        #expect(!sentences.isEmpty)
        #expect(zip(sentences, sentences.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(sentences.last!.end <= duration + 1)
    }
}
