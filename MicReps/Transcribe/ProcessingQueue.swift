import Foundation
import Observation

/// 文字起こしとチャプター作成を1件ずつ順に行う。待ち行列は保存しない。
/// 済んでいない録音は状態が pending のまま残るので、次回起動時に続きから行われる。
@MainActor
@Observable
final class ProcessingQueue {
    private(set) var currentID: UUID?
    private(set) var progress: Double = 0
    private(set) var waiting: [UUID] = []
    private(set) var isInstallingModel = false

    @ObservationIgnored var onNotice: (String) -> Void = { _ in }

    private let store: RecordingStore
    private let transcriber: Transcriber
    private let generator: ChapterGenerator
    private let reviewer: SentenceReviewer
    private let locale: () -> Locale
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(
        store: RecordingStore, transcriber: Transcriber, generator: ChapterGenerator,
        reviewer: SentenceReviewer = AppleSentenceReviewer(), locale: @escaping () -> Locale
    ) {
        self.store = store
        self.transcriber = transcriber
        self.generator = generator
        self.reviewer = reviewer
        self.locale = locale
    }

    func isQueued(_ id: UUID) -> Bool { currentID == id || waiting.contains(id) }

    /// 処理中の録音も積み直す。後の段階の最中に前の段階のやり直しを頼まれたとき、取りこぼさないため。
    /// 各段階は始める前に要否を確かめるので、済んだ段階は飛ばされる。
    func enqueue(_ id: UUID) {
        guard !waiting.contains(id) else { return }
        waiting.append(id)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    func enqueuePending() throws {
        for recording in try store.all().reversed() {
            // 前回はApple Intelligenceが使えなかったものも、今は使えるかもしれない。
            if recording.chapterState == .unavailable { try store.markChapters(recording, .pending) }
            if recording.reviewState == .unavailable { try store.markReview(recording, .pending) }
            // 計り方を変えた版より前の分析は作り直す。
            if recording.analysisState == .done,
               (recording.analysis?.version ?? 0) < SpeakingAnalysis.currentVersion {
                try store.markAnalysis(recording, .pending)
            }
            if recording.needsProcessing { enqueue(recording.id) }
        }
    }

    /// やり直し。新しい結果が出るまで、今の文字起こしは残す。
    func retry(_ recording: Recording) throws {
        recording.transcriptState = .pending
        recording.transcriptMessage = nil
        try store.saveOrRollback()
        enqueue(recording.id)
    }

    /// 章を作り直す。新しい結果が出るまで、今の章は残す。
    func regenerateChapters(_ recording: Recording) throws {
        try store.markChapters(recording, .pending)
        enqueue(recording.id)
    }

    func installModel() async {
        guard !isInstallingModel else { return }
        isInstallingModel = true
        defer { isInstallingModel = false }
        do {
            try await transcriber.installModel(for: locale())
            for recording in try store.all() where recording.transcriptState == .needsModel {
                try retry(recording)
            }
        } catch {
            onNotice("文字起こし用のデータを取得できませんでした。\(error.localizedDescription)")
        }
    }

    func supportedLocales() async -> [Locale] { await transcriber.supportedLocales() }

    /// 行列が空になるまで待つ。
    func waitUntilIdle() async { await worker?.value }

    private func drain() async {
        while !waiting.isEmpty {
            let id = waiting.removeFirst()
            currentID = id
            progress = 0
            await transcribe(id)
            progress = 0
            await analyze(id)
            progress = 0
            await makeChapters(id)
            progress = 0
            await review(id)
            currentID = nil
        }
        worker = nil
    }

    /// 話し方の分析を作り直す。
    func reanalyze(_ recording: Recording) throws {
        try store.markAnalysis(recording, .pending)
        enqueue(recording.id)
    }

    private func analyze(_ id: UUID) async {
        guard let recording = store.recording(id), recording.needsAnalysis,
              var transcript = recording.transcript else { return }
        let url = store.paths.audio(recording)
        let report: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                if self?.currentID == id { self?.progress = value }
            }
        }
        let outcome: Result<SpeakingAnalysis, Error>
        do {
            // 段階5より前の文字起こしには文字ごとの時刻が無い。本文が同じなら時刻だけを足す。
            // 取り直せなくても、文の中で時刻を見積もって分析は続ける。
            if transcript.sentences.contains(where: { $0.times == nil }),
               let pieces = try? await transcriber.transcribe(url, locale: Locale(identifier: transcript.locale), onProgress: { _ in }) {
                let rebuilt = SentenceBuilder.build(pieces)
                if rebuilt.map(\.text) == transcript.sentences.map(\.text) {
                    transcript.sentences = rebuilt
                    if let recording = store.recording(id) { try store.attachTimes(rebuilt, to: recording) }
                }
            }
            outcome = .success(try await SpeakingAnalyzer.analyze(url, sentences: transcript.sentences, onProgress: report))
        } catch {
            outcome = .failure(error)
        }
        guard let recording = store.recording(id) else { return }
        do {
            switch outcome {
            case .success(let analysis): try store.saveAnalysis(analysis, to: recording)
            case .failure(let error): try store.markAnalysis(recording, .failed, message: error.localizedDescription)
            }
        } catch {
            onNotice("話し方の分析を保存できませんでした。\(error.localizedDescription)")
        }
    }

    /// 文を見直し直す。
    func rereview(_ recording: Recording) throws {
        try store.markReview(recording, .pending)
        enqueue(recording.id)
    }

    private func review(_ id: UUID) async {
        guard let recording = store.recording(id), recording.needsReview,
              let transcript = recording.transcript, let analysis = recording.analysis else { return }
        let locale = Locale(identifier: transcript.locale)
        let spoken = SpokenSentence.build(transcript.sentences, fillers: analysis.fillers)
        let chapters = recording.chapters
        let outcome: Result<SentenceReview, Error>
        do {
            if let reason = reviewer.unavailableReason(for: locale) { throw ReviewError.unavailable(reason) }
            outcome = .success(try await SentenceReviewBuilder.build(
                spoken, issues: analysis.issues, chapters: chapters, reviewer: reviewer,
                onProgress: { [weak self] value in
                    Task { @MainActor in
                        if self?.currentID == id { self?.progress = value }
                    }
                }
            ))
        } catch {
            outcome = .failure(error)
        }
        guard let recording = store.recording(id) else { return }
        do {
            switch outcome {
            case .success(let review): try store.saveReview(review, to: recording)
            case .failure(let error):
                var state = ReviewState.failed
                if case .unavailable = error as? ReviewError { state = .unavailable }
                try store.markReview(recording, state, message: error.localizedDescription)
            }
        } catch {
            onNotice("文の見直しを保存できませんでした。\(error.localizedDescription)")
        }
    }

    private func makeChapters(_ id: UUID) async {
        guard let recording = store.recording(id), recording.needsChapters,
              let transcript = recording.transcript else { return }
        let locale = Locale(identifier: transcript.locale)
        var outcome: Result<[Chapter], Error>?
        if !ChapterBuilder.isTooShort(transcript.sentences) {
            do {
                if let reason = generator.unavailableReason(for: locale) { throw ChapterError.unavailable(reason) }
                outcome = .success(try await ChapterBuilder.build(
                    transcript.sentences, locale: locale, generator: generator,
                    onProgress: { self.progress = $0 }
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        guard let recording = store.recording(id) else { return }
        do {
            switch outcome {
            case nil: try store.markChapters(recording, .tooShort)
            case .success(let chapters): try store.saveChapters(chapters, to: recording)
            case .failure(let error):
                var state = ChapterState.failed
                if case .unavailable = error as? ChapterError { state = .unavailable }
                try store.markChapters(recording, state, message: error.localizedDescription)
            }
        } catch {
            onNotice("チャプターを保存できませんでした。\(error.localizedDescription)")
        }
    }

    private func transcribe(_ id: UUID) async {
        guard let recording = store.recording(id), recording.needsTranscription else { return }
        let locale = locale()
        let url = store.paths.audio(recording)
        let outcome: Result<[Sentence], Error>
        do {
            let pieces = try await transcriber.transcribe(url, locale: locale) { [weak self] value in
                Task { @MainActor in
                    if self?.currentID == id { self?.progress = value }
                }
            }
            outcome = .success(SentenceBuilder.build(pieces))
        } catch {
            outcome = .failure(error)
        }
        // 待っている間に完全に削除されていることがあるので、取り直す。
        guard let recording = store.recording(id) else { return }
        do {
            switch outcome {
            case .success(let sentences):
                try store.saveTranscript(Transcript(locale: locale.identifier(.bcp47), sentences: sentences), to: recording)
            case .failure(let error):
                try store.markTranscriptFailed(recording, error: error)
            }
        } catch {
            onNotice("文字起こしを保存できませんでした。\(error.localizedDescription)")
        }
    }
}
