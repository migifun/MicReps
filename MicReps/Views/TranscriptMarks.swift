import Foundation

/// 読むモードで、1文ごとに付ける印。分析と見直しの結果を、文の中の位置に直したもの。
struct SentenceMarks: Equatable, Sendable {
    struct Span: Equatable, Sendable {
        var offset: Int
        var length: Int
        /// フィラーが推定かどうか(言い直しでは使わない)。
        var isCertain = true
    }

    struct InlinePause: Equatable, Sendable {
        /// この文字の前に入れる。
        var offset: Int
        var length: Double
    }

    struct Badge: Equatable, Sendable, Identifiable {
        var kind: SpeakingAnalysis.FindingKind
        var detail: String
        var rewrite: String?
        var id: String { "\(kind.rawValue)-\(detail)" }
    }

    var fillers: [Span] = []
    var restarts: [Span] = []
    var pauses: [InlinePause] = []
    var badges: [Badge] = []
    /// この文の前に始まる章の見出し。
    var chapter: String?
    /// この文のあとの間(次の文までの無音)。
    var pauseAfter: Double?
}

enum TranscriptMarks {
    /// 読むモードで見せる間の長さ。
    static let minimumPause = 1.0

    static func build(
        _ sentences: [Sentence], analysis: SpeakingAnalysis?, review: SentenceReview?, chapters: [Chapter]
    ) -> [SentenceMarks] {
        var marks = [SentenceMarks](repeating: .init(), count: sentences.count)
        guard !sentences.isEmpty else { return marks }

        for chapter in chapters {
            let index = sentences.firstIndex { $0.start >= chapter.start - 0.02 } ?? sentences.count - 1
            marks[index].chapter = marks[index].chapter.map { "\($0) / \(chapter.title)" } ?? chapter.title
        }
        guard let analysis else { return marks }

        for filler in analysis.fillers where marks.indices.contains(filler.sentence) {
            marks[filler.sentence].fillers.append(.init(offset: filler.offset, length: filler.length, isCertain: filler.isCertain))
        }

        for pause in analysis.pauses where pause.length >= minimumPause {
            let middle = pause.start + pause.length / 2
            // 文の途中の間は、その位置に入れる。文と文の間なら、前の文のあとに置く。
            if let index = sentences.lastIndex(where: { $0.start <= middle }) {
                let sentence = sentences[index]
                if middle < sentence.end, let offset = offset(in: sentence, at: pause.start + pause.length) {
                    marks[index].pauses.append(.init(offset: snapped(offset, in: sentence.text), length: pause.length))
                } else {
                    marks[index].pauseAfter = max(marks[index].pauseAfter ?? 0, pause.length)
                }
            }
        }

        for issue in analysis.issues where issue.kind == .restart {
            let phrase = issue.detail.trimmingCharacters(in: CharacterSet(charactersIn: "「」"))
            // 言い直しは話した文の中のどこか。最初の文から順に探す。
            for index in issue.sentence..<min(sentences.count, issue.sentence + 4) {
                let text = sentences[index].text
                if let range = text.range(of: phrase) {
                    marks[index].restarts.append(.init(
                        offset: text.distance(from: text.startIndex, to: range.lowerBound), length: phrase.count
                    ))
                    break
                }
            }
        }

        let badgeKinds: Set<SpeakingAnalysis.FindingKind> = [
            .longSentence, .modifiers, .offTopic, .monotone, .weakEnding, .fast, .slow,
        ]
        for finding in analysis.findings(sentences, review: review) where badgeKinds.contains(finding.kind) {
            guard let index = finding.sentence, marks.indices.contains(index) else { continue }
            marks[index].badges.append(.init(kind: finding.kind, detail: badgeDetail(finding), rewrite: finding.rewrite))
        }
        return marks
    }

    /// その時刻に話していた文字の位置。
    static func offset(in sentence: Sentence, at time: Double) -> Int? {
        let count = sentence.text.count
        guard count > 0 else { return nil }
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if sentence.time(at: middle) < time { low = middle + 1 } else { high = middle }
        }
        return low > 0 && low < count ? low : nil
    }

    /// 言葉の途中に入らないよう、近くの読点や句点の後ろへずらす。近くに無ければそのまま。
    static func snapped(_ offset: Int, in text: String, within distance: Int = 6) -> Int {
        let characters = Array(text)
        let breaks: Set<Character> = ["、", "。", "，", "？", "！", " "]
        let candidates = (1..<characters.count).filter { breaks.contains(characters[$0 - 1]) }
        guard let nearest = candidates.min(by: { abs($0 - offset) < abs($1 - offset) }),
              abs(nearest - offset) <= distance else { return offset }
        return nearest
    }

    /// 文の中で、その時刻までに話し終えた文字数。
    static func playedCount(in sentence: Sentence, at time: Double) -> Int {
        let count = sentence.text.count
        if time >= sentence.end { return count }
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if sentence.time(at: middle) <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// 文の横に出すので、文の書き出しは省いて短くする。
    private static func badgeDetail(_ finding: SpeakingAnalysis.Finding) -> String {
        switch finding.kind {
        case .monotone, .fast, .slow:
            String(finding.detail.prefix { $0 != " " })
        case .weakEnding:
            String(finding.detail.prefix { $0 != " " })
        case .offTopic:
            ""
        default:
            finding.detail
        }
    }
}
