import Foundation

/// 話し方の分析結果。音声ファイルと文字起こしから、いつでも作り直せる。
struct SpeakingAnalysis: Codable, Equatable, Sendable {
    /// 計り方を変えたら上げる。古い版の結果は起動時に作り直す。
    static let currentVersion = 2

    var version = Self.currentVersion
    var duration: Double
    /// 長い無音(画面を見せているときなど)を除いた、話していた時間。
    var speakingTime: Double
    /// 雑音の大きさと、無音とみなした基準(dB)。
    var noiseFloor: Float
    var silenceThreshold: Float

    var pauses: [Pause]
    var fillers: [Filler]
    var habits: [Habit]
    /// transcript.sentences と同じ並び。
    var sentences: [SentenceVoice]
    /// グラフ用に間引いた声の高さ(録音全体の中央値からの半音差。声が無いところは nil)と大きさ(dB)。
    var pitchContour: [Float?]
    var volumeContour: [Float]
    /// 段階6で追加。文の長さ、修飾の重なり、言い直し。
    var issues: [SentenceIssue]

    struct SentenceIssue: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case long, modifiers, restart
        }

        var kind: Kind
        /// 話した文の最初の、文字起こしの文の番号。
        var sentence: Int
        var time: Double
        var detail: String
    }

    struct Pause: Codable, Equatable, Sendable {
        var start: Double
        var length: Double
    }

    struct Filler: Codable, Equatable, Sendable {
        var sentence: Int
        /// 文の中の文字の位置と長さ(Character単位)。
        var offset: Int
        var length: Int
        var time: Double
        var word: String
        /// 「えっと」のように必ずフィラーになる語か、「あの」のように前後から推定したものか。
        var isCertain: Bool
    }

    struct Habit: Codable, Equatable, Sendable {
        var word: String
        var count: Int
    }

    struct SentenceVoice: Codable, Equatable, Sendable {
        /// 声の高さの中央値(Hz)。声が取れなければ nil。
        var pitch: Float?
        /// 文の中の声の高さの幅(半音。10〜90%の範囲)。
        var pitchRange: Float?
        /// 声の大きさの平均(dB)。
        var volume: Float?
        /// 文の最後0.6秒の大きさと、文全体の差(dB)。マイナスほど語尾が弱い。
        var tailDrop: Float?
        /// 1秒あたりの音の数(モーラ)。
        var rate: Float?
    }
}

// MARK: - まとめと指摘

extension SpeakingAnalysis {
    /// この長さ以上の無音は、話していない時間として間に数えない。
    static let silenceLimit = 8.0
    static let longPause = 2.0

    var fillersPerMinute: Double { speakingTime > 0 ? Double(fillers.count) / speakingTime * 60 : 0 }

    /// 話の中の間(長い無音は除く)。
    var spokenPauses: [Pause] { pauses.filter { $0.length < Self.silenceLimit } }

    var medianRate: Float? { Self.median(sentences.compactMap(\.rate)) }
    var medianPitch: Float? { Self.median(sentences.compactMap(\.pitch)) }
    var medianPitchRange: Float? { Self.median(sentences.compactMap(\.pitchRange)) }

    /// 文ごとの声の大きさの、ふだんの幅(10〜90%)。
    var volumeSpread: Float? {
        let values = sentences.compactMap(\.volume).sorted()
        guard values.count >= 3 else { return nil }
        return values[values.count * 9 / 10] - values[values.count / 10]
    }

    enum FindingKind: String, CaseIterable, Sendable {
        case filler, longPause, silence, monotone, weakEnding, fast, slow
        case longSentence, modifiers, restart, offTopic

        var title: String {
            switch self {
            case .filler: "フィラー"
            case .longPause: "長い間"
            case .silence: "話していない時間"
            case .monotone: "抑揚が小さい"
            case .weakEnding: "語尾が弱い"
            case .fast: "速い"
            case .slow: "ゆっくり"
            case .longSentence: "長い文"
            case .modifiers: "飾る言葉が多い"
            case .restart: "言い直し"
            case .offTopic: "本題から外れている"
            }
        }
    }

    struct Finding: Identifiable, Equatable, Sendable {
        var kind: FindingKind
        var time: Double
        var detail: String
        /// 関係する文の番号。
        var sentence: Int?
        /// AIが作った言い直しの例。
        var rewrite: String?
        var id: String { "\(kind.rawValue)-\(time)-\(detail)" }
    }

    static let monotoneRange: Float = 3.5
    static let monotoneMinimumLength = 4.0
    static let weakEndingDrop: Float = -8
    static let rateRatio: Float = 1.3

    /// 指摘の一覧。sentences は分析に使った文字起こしの文。
    func findings(_ sentences: [Sentence], review: SentenceReview? = nil) -> [Finding] {
        var result: [Finding] = []
        let rewrites = Dictionary((review?.rewrites ?? []).map { ($0.sentence, $0.text) }, uniquingKeysWith: { a, _ in a })
        for issue in issues {
            let kind: FindingKind = switch issue.kind {
            case .long: .longSentence
            case .modifiers: .modifiers
            case .restart: .restart
            }
            result.append(Finding(
                kind: kind, time: issue.time, detail: issue.detail, sentence: issue.sentence,
                rewrite: issue.kind == .restart ? nil : rewrites[issue.sentence]
            ))
        }
        for item in review?.offTopic ?? [] where sentences.indices.contains(item) {
            result.append(Finding(
                kind: .offTopic, time: sentences[item].start, detail: Self.preview(sentences[item].text), sentence: item
            ))
        }
        for filler in fillers {
            result.append(Finding(
                kind: .filler, time: filler.time,
                detail: filler.isCertain ? "「\(filler.word)」" : "「\(filler.word)」(推定)", sentence: filler.sentence
            ))
        }
        for pause in pauses where pause.length >= Self.longPause {
            let kind: FindingKind = pause.length >= Self.silenceLimit ? .silence : .longPause
            result.append(Finding(kind: kind, time: pause.start, detail: String(format: "%.1f秒", pause.length)))
        }
        let rate = medianRate
        for (i, voice) in self.sentences.enumerated() where i < sentences.count {
            let sentence = sentences[i]
            let preview = Self.preview(sentence.text)
            if let range = voice.pitchRange, range < Self.monotoneRange,
               sentence.end - sentence.start >= Self.monotoneMinimumLength {
                result.append(Finding(
                    kind: .monotone, time: sentence.start, detail: String(format: "%.1f半音 %@", range, preview), sentence: i
                ))
            }
            if let drop = voice.tailDrop, drop <= Self.weakEndingDrop {
                result.append(Finding(
                    kind: .weakEnding, time: sentence.start,
                    detail: String(format: "%.0fdB …%@", drop, String(sentence.text.suffix(12))), sentence: i
                ))
            }
            if let rate, rate > 0, let own = voice.rate, sentence.end - sentence.start >= 2 {
                if own >= rate * Self.rateRatio {
                    result.append(Finding(kind: .fast, time: sentence.start,
                                          detail: String(format: "%.1f音/秒 %@", own, preview), sentence: i))
                } else if own <= rate / Self.rateRatio {
                    result.append(Finding(kind: .slow, time: sentence.start,
                                          detail: String(format: "%.1f音/秒 %@", own, preview), sentence: i))
                }
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    private static func preview(_ text: String) -> String {
        text.count > 14 ? String(text.prefix(14)) + "…" : text
    }

    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
