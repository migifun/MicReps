import AppKit
import Foundation
import Testing
@testable import MicReps

@MainActor
struct AppModelTests {
    let paths: AppPaths
    let model: AppModel
    let capture = FakeCapture()
    let transcriber = FakeTranscriber()
    let generator = FakeGenerator()
    let reviewer = FakeReviewer()

    init() throws {
        paths = try makePaths()
        model = try AppModel(paths: paths, capture: capture, transcriber: transcriber, generator: generator, reviewer: reviewer)
    }

    private func record(seconds: Double) async throws -> Recording {
        await model.recorder.start()
        capture.onBuffer?(tone(seconds: seconds, gain: 0))
        await model.recorder.finish()?.value
        return try #require(try model.store.all().first)
    }

    @Test func 完了した録音が選ばれキーで移動できる() async throws {
        let recording = try await record(seconds: 40)
        #expect(model.selection == recording.id)
        model.showInPlayer(recording)
        #expect(model.handlePlaybackKey(124))
        #expect(model.player.position == 15)
        #expect(model.handlePlaybackKey(123))
        #expect(model.player.position == 0)
        #expect(model.handlePlaybackKey(49))
        #expect(model.player.isPlaying)
        #expect(model.handlePlaybackKey(49))
        #expect(!model.player.isPlaying)
        #expect(!model.handlePlaybackKey(0))
    }

    @Test func 録音中は再生のキーが効かない() async throws {
        let recording = try await record(seconds: 40)
        model.showInPlayer(recording)
        await model.recorder.start()
        #expect(!model.handlePlaybackKey(49))
        #expect(!model.player.isPlaying)
        model.recorder.finish()
    }

    @Test func 削除すると再生と選択が外れる() async throws {
        let recording = try await record(seconds: 2)
        model.showInPlayer(recording)
        model.moveToTrash(recording)
        #expect(model.selection == nil)
        #expect(!model.player.isLoaded)
        model.deletePermanently(recording)
        #expect(try model.store.all().isEmpty)
    }

    @Test func 二つ目の起動は断る() throws {
        #expect(throws: AppModel.LaunchError.self) {
            try AppModel(paths: paths, capture: FakeCapture(), reviewer: FakeReviewer())
        }
    }

    @Test func 録音を終えると文字起こしまで自動で進む() async throws {
        let recording = try await record(seconds: 2)
        await model.queue.waitUntilIdle()
        #expect(recording.transcriptState == .done)
        #expect(recording.transcript?.sentences.map(\.text) == ["こんにちは。"])
        #expect(recording.transcriptText == "こんにちは。")
        #expect(transcriber.calls == [paths.m4a(recording.id)])
    }

    @Test func ゴミ箱の録音は文字起こしせず元に戻すと行う() async throws {
        transcriber.result = .failure(CocoaError(.fileReadUnknown))
        let recording = try await record(seconds: 2)
        await model.queue.waitUntilIdle()
        #expect(recording.transcriptState == .failed)
        transcriber.result = .success([TimedText(text: "戻した。", start: 0, end: 1)])
        model.moveToTrash(recording)
        model.retranscribe(recording)
        await model.queue.waitUntilIdle()
        #expect(recording.transcriptState == .pending)
        model.restore(recording)
        await model.queue.waitUntilIdle()
        #expect(recording.transcriptState == .done)
    }

    @Test func 編集できない本文では再生のキーを効かせる() {
        let text = NSTextView()
        text.isEditable = false
        #expect(!AppModel.isTyping(text))
        text.isEditable = true
        #expect(AppModel.isTyping(text))
        #expect(!AppModel.isTyping(nil))
    }

    /// 60秒ぶん、5秒ごとの文。
    private func longSpeech() -> [TimedText] {
        (0..<12).map { TimedText(text: "これは\($0)番目の話です。", start: Double($0) * 5, end: Double($0) * 5 + 5) }
    }

    private func recordWithChapters() async throws -> Recording {
        transcriber.result = .success(longSpeech())
        generator.answer = { _ in [
            ChapterProposal(title: "最初", firstSentence: "これは0番目の話です。"),
            ChapterProposal(title: "後半", firstSentence: "これは6番目の話です。"),
        ] }
        let recording = try await record(seconds: 60)
        await model.queue.waitUntilIdle()
        model.showInPlayer(recording)
        return recording
    }

    @Test func 録音を終えるとチャプターまで自動で作られ移動できる() async throws {
        let recording = try await recordWithChapters()
        #expect(recording.chapterState == .done)
        #expect(recording.chapters.map(\.title) == ["最初", "後半"])
        #expect(recording.chapters.map(\.start) == [0, 30])
        #expect(model.jumpToChapter(forward: true))
        #expect(model.player.position == 30)
        #expect(!model.jumpToChapter(forward: true))
        #expect(model.jumpToChapter(forward: false))
        #expect(model.player.position == 0)
    }

    @Test func チャプターの名前変更と削除が保存される() async throws {
        let recording = try await recordWithChapters()
        let second = recording.chapters[1].id
        model.renameChapter(second, in: recording, to: "  まとめ ")
        #expect(recording.chapters[1].title == "まとめ")
        #expect(recording.chapters[1].isEdited)
        model.renameChapter(second, in: recording, to: "   ")
        #expect(recording.chapters[1].title == "まとめ")
        model.deleteChapter(second, in: recording)
        #expect(recording.chapters.map(\.title) == ["最初"])
    }

    @Test func 手を入れた章があれば作り直す前に確認する() async throws {
        let recording = try await recordWithChapters()
        model.requestChapterRegeneration(recording)
        #expect(model.confirmingRegeneration == nil)
        await model.queue.waitUntilIdle()
        model.renameChapter(recording.chapters[0].id, in: recording, to: "変更")
        model.requestChapterRegeneration(recording)
        #expect(model.confirmingRegeneration === recording)
        #expect(recording.chapters[0].title == "変更")
        model.regenerateChapters(recording)
        await model.queue.waitUntilIdle()
        #expect(recording.chapters[0].title == "最初")
    }

    @Test func 文字起こしをやり直しても手を入れた章は残る() async throws {
        let recording = try await recordWithChapters()
        model.retranscribe(recording)
        await model.queue.waitUntilIdle()
        #expect(recording.chapters.map(\.title) == ["最初", "後半"])
        let calls = generator.calls
        model.renameChapter(recording.chapters[0].id, in: recording, to: "変更")
        model.retranscribe(recording)
        await model.queue.waitUntilIdle()
        #expect(recording.chapters.map(\.title) == ["変更", "後半"])
        #expect(generator.calls == calls)
    }

    @Test func 作り直しに失敗しても前の章は残る() async throws {
        let recording = try await recordWithChapters()
        generator.answer = { _ in throw ChapterError.refused }
        model.regenerateChapters(recording)
        await model.queue.waitUntilIdle()
        #expect(recording.chapterState == .failed)
        #expect(recording.chapters.count == 2)
    }

    @Test func AppleIntelligenceが使えなくても文字起こしは使え後で作れる() async throws {
        generator.reason = "オフです"
        let recording = try await recordWithChapters()
        #expect(recording.transcriptState == .done)
        #expect(recording.chapterState == .unavailable)
        #expect(recording.chapterMessage == "オフです")
        generator.reason = nil
        try model.queue.enqueuePending()
        await model.queue.waitUntilIdle()
        #expect(recording.chapterState == .done)
        #expect(transcriber.calls.count == 1)
    }

    @Test func 短い録音ではAIを呼ばない() async throws {
        let recording = try await record(seconds: 2)
        await model.queue.waitUntilIdle()
        #expect(recording.chapterState == .tooShort)
        #expect(generator.calls == 0)
    }

    @Test func 後の段階の最中に頼んだ章の作り直しも行う() async throws {
        // 長い文があると、章が無くても見直し(言い直しの例)が走る。
        var speech = longSpeech()
        speech[11].text = "これは11番目の話です" + String(repeating: "とても長い説明を続けています", count: 7) + "。"
        transcriber.result = .success(speech)
        generator.answer = { _ in throw ChapterError.refused }
        let model = model, generator = generator
        reviewer.once = {
            // 章の作成に失敗し、見直しをしている最中に「もう一度試す」を押す。
            generator.answer = { _ in [
                ChapterProposal(title: "最初", firstSentence: "これは0番目の話です。"),
                ChapterProposal(title: "後半", firstSentence: "これは6番目の話です。"),
            ] }
            guard let recording = try? model.store.all().first else { return }
            #expect(recording.chapterState == .failed)
            #expect(model.queue.currentID == recording.id)
            model.requestChapterRegeneration(recording)
        }
        let recording = try await record(seconds: 60)
        await model.queue.waitUntilIdle()
        #expect(reviewer.once == nil)
        #expect(recording.chapterState == .done)
        #expect(recording.chapters.map(\.title) == ["最初", "後半"])
        #expect(!model.queue.isQueued(recording.id))
        // 済んでいた文字起こしはやり直さない。
        #expect(transcriber.calls.count == 1)
    }
}
