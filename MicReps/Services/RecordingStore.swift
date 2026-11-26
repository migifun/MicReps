import Foundation
import SwiftData

/// 録音の一覧と音声ファイルの管理。
@MainActor
final class RecordingStore {
    static let trashLifetime: TimeInterval = 30 * 24 * 60 * 60

    let paths: AppPaths
    /// ModelContextはコンテナを保持しないため、こちらで持っておく。
    private let container: ModelContainer
    let context: ModelContext
    private(set) var finalizations: [UUID: Task<Void, Never>] = [:]
    /// 音声の保存が終わり、再生や文字起こしができるようになったとき。
    var onReady: (UUID) -> Void = { _ in }

    init(paths: AppPaths, container: ModelContainer) {
        self.paths = paths
        self.container = container
        self.context = container.mainContext
        // 保存の成否を確認してから次へ進むため、自動保存は使わない。
        context.autosaveEnabled = false
    }

    func all() throws -> [Recording] {
        try context.fetch(FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    func recording(_ id: UUID) -> Recording? {
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func createForRecording() throws -> Recording {
        let id = UUID()
        let recording = Recording(
            id: id, title: try nextTitle(), audioFileName: paths.caf(id).lastPathComponent, state: .recording
        )
        context.insert(recording)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return recording
    }

    /// 取り込んだ音声を録音として加える。先に名前を変えるので、途中で落ちても次回起動時に拾われる。
    func createImported(id: UUID, title: String, createdAt: Date, from partial: URL) throws -> Recording {
        let caf = paths.caf(id)
        try FileManager.default.moveItem(at: partial, to: caf)
        let recording = Recording(
            id: id, title: title.isEmpty ? try nextTitle() : title, createdAt: createdAt,
            audioFileName: caf.lastPathComponent, state: .converting
        )
        context.insert(recording)
        do {
            try context.save()
        } catch {
            context.rollback()
            try? FileManager.default.removeItem(at: caf)
            throw error
        }
        return recording
    }

    func nextTitle() throws -> String {
        let used = Set(try all().map(\.title))
        let base = "新規録音"
        if !used.contains(base) { return base }
        var number = 2
        while used.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// 録音できなかったものを跡形なく消す。
    func discard(_ recording: Recording) throws {
        try deleteFilesAndRow(recording)
    }

    func rename(_ recording: Recording, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != recording.title else { return }
        recording.title = trimmed
        try saveOrRollback()
    }

    func moveToTrash(_ recording: Recording, now: Date = .now) throws {
        guard recording.isSettled else { return }
        recording.trashedAt = now
        try saveOrRollback()
    }

    func restore(_ recording: Recording) throws {
        recording.trashedAt = nil
        try saveOrRollback()
    }

    func deletePermanently(_ recording: Recording) throws {
        guard recording.isSettled, recording.trashedAt != nil else { return }
        try deleteFilesAndRow(recording)
    }

    func emptyTrash() throws {
        for recording in try all() where recording.trashedAt != nil { try deletePermanently(recording) }
    }

    func purgeExpiredTrash(now: Date = .now) throws {
        for recording in try all() {
            if let trashedAt = recording.trashedAt, now.timeIntervalSince(trashedAt) > Self.trashLifetime {
                try deletePermanently(recording)
            }
        }
    }

    func saveTranscript(_ transcript: Transcript, to recording: Recording) throws {
        recording.transcriptData = try JSONEncoder().encode(transcript)
        recording.transcriptText = transcript.text(.plain)
        recording.transcribedAt = .now
        recording.transcriptMessage = nil
        recording.transcriptState = transcript.sentences.isEmpty ? .noSpeech : .done
        recording.analysisData = nil
        recording.analysisMessage = nil
        recording.analyzedAt = nil
        recording.analysisState = .pending
        // 手を入れた章は時刻で持っているので、そのまま使える。そうでなければ作り直す。
        if !recording.chapters.contains(where: \.isEdited) {
            recording.chapterData = nil
            recording.chapterMessage = nil
            recording.chapterState = .pending
        }
        try saveOrRollback()
    }

    func saveChapters(_ chapters: [Chapter], to recording: Recording) throws {
        recording.chapterData = try JSONEncoder().encode(chapters.sorted { $0.start < $1.start })
        recording.chapterMessage = nil
        recording.chapterState = .done
        try saveOrRollback()
    }

    func saveAnalysis(_ analysis: SpeakingAnalysis, to recording: Recording) throws {
        recording.analysisData = try JSONEncoder().encode(analysis)
        recording.analysisMessage = nil
        recording.analyzedAt = .now
        recording.analysisState = .done
        // 見直しは分析の結果(長い文)をもとにするので、作り直す。
        recording.reviewData = nil
        recording.reviewMessage = nil
        recording.reviewState = .pending
        try saveOrRollback()
    }

    func saveReview(_ review: SentenceReview, to recording: Recording) throws {
        recording.reviewData = try JSONEncoder().encode(review)
        recording.reviewMessage = nil
        recording.reviewState = .done
        try saveOrRollback()
    }

    func markReview(_ recording: Recording, _ state: ReviewState, message: String? = nil) throws {
        recording.reviewState = state
        recording.reviewMessage = message
        try saveOrRollback()
    }

    func markAnalysis(_ recording: Recording, _ state: AnalysisState, message: String? = nil) throws {
        recording.analysisState = state
        recording.analysisMessage = message
        try saveOrRollback()
    }

    /// 文字ごとの時刻が無い古い文字起こしに、本文を変えずに時刻だけを足す。章には触れない。
    func attachTimes(_ sentences: [Sentence], to recording: Recording) throws {
        guard var transcript = recording.transcript,
              transcript.sentences.map(\.text) == sentences.map(\.text) else { return }
        transcript.sentences = sentences
        recording.transcriptData = try JSONEncoder().encode(transcript)
        try saveOrRollback()
    }

    func markChapters(_ recording: Recording, _ state: ChapterState, message: String? = nil) throws {
        recording.chapterState = state
        recording.chapterMessage = message
        try saveOrRollback()
    }

    func markTranscriptFailed(_ recording: Recording, error: Error) throws {
        recording.transcriptState = error as? TranscriberError == .needsModel ? .needsModel : .failed
        recording.transcriptMessage = error.localizedDescription
        try saveOrRollback()
    }

    /// 変換を始める。録音完了時・起動時の復元・失敗後のやり直しで使う。
    @discardableResult
    func beginFinalizing(_ recording: Recording) -> Task<Void, Never> {
        let id = recording.id
        if let running = finalizations[id] { return running }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.finalize(recording)
            self.finalizations[id] = nil
        }
        finalizations[id] = task
        return task
    }

    private func finalize(_ recording: Recording) async {
        let caf = paths.caf(recording.id)
        let m4a = paths.m4a(recording.id)
        do {
            recording.state = .converting
            recording.failureMessage = nil
            try context.save()
            let output = try await AudioFinalizer.finalize(caf: caf, m4a: m4a)
            recording.duration = output.duration
            recording.waveform = output.waveform
            recording.audioFileName = m4a.lastPathComponent
            recording.state = .ready
            // 保存できたことを確かめてから元の音声を消す。
            try context.save()
            try? FileManager.default.removeItem(at: caf)
            onReady(recording.id)
        } catch {
            let existing = [caf, m4a].first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
            if let existing { recording.audioFileName = existing.lastPathComponent }
            recording.state = .failed
            recording.failureMessage = error.localizedDescription
            try? context.save()
        }
    }

    /// 起動時に一度だけ呼ぶ。異常終了で残ったものを拾い直す。戻り値は復元した件数。
    func recover() throws -> Int {
        let files = FileManager.default
        let names = try files.contentsOfDirectory(atPath: paths.recordings.path(percentEncoded: false))
        for name in names where name.hasSuffix(".partial.m4a") || name.hasSuffix(AudioImporter.partialSuffix) {
            try? files.removeItem(at: paths.recordings.appending(path: name))
        }

        let rows = try all()
        var recovered = 0
        for recording in rows {
            let hasCAF = files.fileExists(atPath: paths.caf(recording.id).path(percentEncoded: false))
            switch recording.state {
            case .recording:
                recording.wasRecovered = true
                recovered += 1
                beginFinalizing(recording)
            case .converting:
                beginFinalizing(recording)
            case .failed:
                if hasCAF { beginFinalizing(recording) }
            case .ready:
                guard hasCAF else { break }
                // 変換後、CAFを消す直前に落ちた場合の残り。m4aは検証済みなので、あれば元を消してよい。
                if files.fileExists(atPath: paths.m4a(recording.id).path(percentEncoded: false)) {
                    try? files.removeItem(at: paths.caf(recording.id))
                } else {
                    beginFinalizing(recording)
                }
            }
        }

        let known = Set(rows.map(\.id))
        var orphans: [UUID: String] = [:]
        for name in names.sorted() {
            let url = URL(filePath: name)
            guard ["caf", "m4a"].contains(url.pathExtension),
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !known.contains(id), orphans[id] == nil
            else { continue }
            orphans[id] = name
        }
        for (id, name) in orphans {
            let url = paths.recordings.appending(path: name)
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            let recording = Recording(
                id: id, title: "復元された録音", createdAt: created, audioFileName: name, state: .converting
            )
            recording.wasRecovered = true
            context.insert(recording)
            recovered += 1
            beginFinalizing(recording)
        }
        try context.save()
        return recovered
    }

    func saveOrRollback() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// ファイルを先に消す。逆順だと、途中で落ちたときに削除済みの録音が復元されてしまう。
    private func deleteFilesAndRow(_ recording: Recording) throws {
        let files = FileManager.default
        for url in [paths.caf(recording.id), paths.m4a(recording.id)] {
            if files.fileExists(atPath: url.path(percentEncoded: false)) { try files.removeItem(at: url) }
        }
        context.delete(recording)
        try saveOrRollback()
    }
}
