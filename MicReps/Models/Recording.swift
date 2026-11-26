import Foundation
import SwiftData

enum RecordingState: String {
    /// 録音中。起動時にこの状態なら、前回異常終了したもの。
    case recording
    /// 録音は終わり、m4aへ変換中。
    case converting
    case ready
    case failed
}

enum TranscriptState: String {
    case pending, done, noSpeech, failed, needsModel
}

enum ChapterState: String {
    case pending, done, tooShort, unavailable, failed
}

enum AnalysisState: String {
    case pending, done, failed
}

enum ReviewState: String {
    case pending, done, unavailable, failed
}

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    /// recordingsフォルダからの相対名。変換前は .caf、変換後は .m4a。
    var audioFileName: String
    var stateRaw: String
    var failureMessage: String?
    var waveform: [Float]
    var trashedAt: Date?
    var wasRecovered: Bool

    // 段階2で追加。既存の録音が開けるよう、すべて初期値を持たせる。
    var transcriptStateRaw: String = "pending"
    var transcriptMessage: String?
    var transcribedAt: Date?
    @Attribute(.externalStorage) var transcriptData: Data?
    /// 一覧の検索用に本文だけを持つ。
    var transcriptText: String = ""

    // 段階3で追加。
    var chapterStateRaw: String = "pending"
    var chapterMessage: String?
    var chapterData: Data?

    // 段階5で追加。
    var analysisStateRaw: String = "pending"
    var analysisMessage: String?
    var analyzedAt: Date?
    @Attribute(.externalStorage) var analysisData: Data?

    // 段階6で追加。
    var reviewStateRaw: String = "pending"
    var reviewMessage: String?
    var reviewData: Data?

    init(id: UUID = UUID(), title: String, createdAt: Date = .now, audioFileName: String, state: RecordingState) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = 0
        self.audioFileName = audioFileName
        self.stateRaw = state.rawValue
        self.waveform = []
        self.wasRecovered = false
    }

    var state: RecordingState {
        get { RecordingState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }

    var transcriptState: TranscriptState {
        get { TranscriptState(rawValue: transcriptStateRaw) ?? .pending }
        set { transcriptStateRaw = newValue.rawValue }
    }

    /// 読み出しのたびに復元するので、頻繁に呼ぶ場所では結果を持っておくこと。
    var transcript: Transcript? {
        transcriptData.flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
    }

    var needsTranscription: Bool {
        state == .ready && trashedAt == nil && transcriptState == .pending
    }

    var chapterState: ChapterState {
        get { ChapterState(rawValue: chapterStateRaw) ?? .pending }
        set { chapterStateRaw = newValue.rawValue }
    }

    var chapters: [Chapter] {
        chapterData.flatMap { try? JSONDecoder().decode([Chapter].self, from: $0) } ?? []
    }

    var needsChapters: Bool {
        state == .ready && trashedAt == nil && transcriptState == .done && chapterState == .pending
    }

    var analysisState: AnalysisState {
        get { AnalysisState(rawValue: analysisStateRaw) ?? .pending }
        set { analysisStateRaw = newValue.rawValue }
    }

    /// 読み出しのたびに復元するので、頻繁に呼ぶ場所では結果を持っておくこと。
    var analysis: SpeakingAnalysis? {
        analysisData.flatMap { try? JSONDecoder().decode(SpeakingAnalysis.self, from: $0) }
    }

    var needsAnalysis: Bool {
        state == .ready && trashedAt == nil && transcriptState == .done && analysisState == .pending
    }

    var reviewState: ReviewState {
        get { ReviewState(rawValue: reviewStateRaw) ?? .pending }
        set { reviewStateRaw = newValue.rawValue }
    }

    var review: SentenceReview? {
        reviewData.flatMap { try? JSONDecoder().decode(SentenceReview.self, from: $0) }
    }

    /// 脱線は章の見出しで判定するので、章ができてから行う。
    var needsReview: Bool {
        state == .ready && trashedAt == nil && analysisState == .done && chapterState != .pending
            && reviewState == .pending
    }

    var needsProcessing: Bool { needsTranscription || needsAnalysis || needsChapters || needsReview }

    /// 処理中は削除や書き換えをさせない。
    var isSettled: Bool { state == .ready || state == .failed }
}
