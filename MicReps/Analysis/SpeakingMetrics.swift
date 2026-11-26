import Foundation

/// 振り返り用に、録音ごとの分析を数値にまとめたもの。
struct SpeakingMetrics: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    var values: [Metric: Double]
    /// 口癖の1分あたりの回数。
    var habits: [String: Double]

    enum Metric: String, CaseIterable, Identifiable, Sendable {
        case fillers, longSentences, restarts, pauses, rate, pitchRange, volumeSpread

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fillers: "フィラー"
            case .longSentences: "長い文"
            case .restarts: "言い直し"
            case .pauses: "間"
            case .rate: "話す速さ"
            case .pitchRange: "抑揚の幅"
            case .volumeSpread: "声の大きさの幅"
            }
        }

        var unit: String {
            switch self {
            case .fillers, .pauses: "回/分"
            case .longSentences, .restarts: "回/10分"
            case .rate: "音/秒"
            case .pitchRange: "半音"
            case .volumeSpread: "dB"
            }
        }

        /// 小さいほど良いなら -1、大きいほど良いなら 1、どちらとも言えなければ 0。
        var better: Int {
            switch self {
            case .fillers, .longSentences, .restarts: -1
            case .pitchRange: 1
            case .pauses, .rate, .volumeSpread: 0
            }
        }

        var help: String {
            switch self {
            case .fillers: "「えっと」「あの」などの数。話していた時間1分あたり。"
            case .longSentences: "80字以上か20秒以上の文の数。話していた時間10分あたり。"
            case .restarts: "「資料の中資料たちの中」のような言い直しの数。話していた時間10分あたり。"
            case .pauses: "0.3〜8秒の間の数。話していた時間1分あたり。"
            case .rate: "1秒あたりの音(かな1文字ぶん)の数。文ごとの中央値。"
            case .pitchRange: "文の中の声の高さの幅。大きいほど抑揚がある。文ごとの中央値。"
            case .volumeSpread: "文ごとの声の大きさのばらつき。大きいほど強弱がある。"
            }
        }
    }

    init?(_ recording: Recording) {
        guard let analysis = recording.analysis, analysis.speakingTime >= 30 else { return nil }
        let minutes = analysis.speakingTime / 60
        id = recording.id
        title = recording.title
        createdAt = recording.createdAt
        duration = recording.duration
        var values: [Metric: Double] = [
            .fillers: analysis.fillersPerMinute,
            .longSentences: Double(analysis.issues.count { $0.kind == .long }) / minutes * 10,
            .restarts: Double(analysis.issues.count { $0.kind == .restart }) / minutes * 10,
            .pauses: Double(analysis.spokenPauses.count) / minutes,
        ]
        values[.rate] = analysis.medianRate.map(Double.init)
        values[.pitchRange] = analysis.medianPitchRange.map(Double.init)
        values[.volumeSpread] = analysis.volumeSpread.map(Double.init)
        self.values = values
        habits = Dictionary(uniqueKeysWithValues: analysis.habits.map { ($0.word, Double($0.count) / minutes) })
    }

    init(id: UUID = UUID(), title: String, createdAt: Date, duration: Double, values: [Metric: Double], habits: [String: Double] = [:]) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.values = values
        self.habits = habits
    }

    /// 自分のふだんの値。最新を除いた録音の中央値。比べる録音が無ければ nil。
    static func baseline(_ metric: Metric, in history: [SpeakingMetrics]) -> Double? {
        let values = history.sorted { $0.createdAt < $1.createdAt }.dropLast().compactMap { $0.values[metric] }.sorted()
        guard !values.isEmpty else { return nil }
        return values.count % 2 == 1
            ? values[values.count / 2]
            : (values[values.count / 2 - 1] + values[values.count / 2]) / 2
    }

    enum Change: Equatable {
        case better, worse, same, neutral
    }

    /// 最新の値がふだんと比べてどうか。5%未満の差は変わらないとみなす。
    static func change(_ metric: Metric, latest: Double, baseline: Double) -> Change {
        let scale = max(abs(baseline), 0.001)
        let ratio = (latest - baseline) / scale
        guard abs(ratio) >= 0.05 else { return .same }
        guard metric.better != 0 else { return .neutral }
        return (ratio > 0) == (metric.better > 0) ? .better : .worse
    }

    /// 全体でよく出る口癖(1分あたりの合計が多い順)。
    static func topHabits(_ history: [SpeakingMetrics], count: Int = 3) -> [String] {
        var totals: [String: Double] = [:]
        for metrics in history {
            for (word, value) in metrics.habits { totals[word, default: 0] += value }
        }
        return totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(count).map(\.key)
    }
}
