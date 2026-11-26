import Foundation

struct Sentence: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    /// text の1文字ごとの開始時刻(段階5で追加)。それより前の文字起こしには無い。
    var times: [Double]?

    init(start: Double, end: Double, text: String, times: [Double]? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.times = times
    }

    /// text の offset 文字目の時刻。1文字ごとの時刻が無ければ、文の中で均等に割り振って見積もる。
    func time(at offset: Int) -> Double {
        if let times, times.indices.contains(offset) { return times[offset] }
        let count = max(1, text.count)
        return start + (end - start) * Double(min(max(offset, 0), count)) / Double(count)
    }
}

struct Transcript: Codable, Equatable, Sendable {
    var locale: String
    var sentences: [Sentence]

    /// その時刻に話されている文。文と文の間では直前の文。
    static func index(at time: Double, in sentences: [Sentence]) -> Int? {
        var low = 0
        var high = sentences.count
        while low < high {
            let middle = (low + high) / 2
            // 文の頭へ移動した直後に、丸め誤差で前の文が選ばれないようにする。
            if sentences[middle].start <= time + 0.02 { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    enum Format: CaseIterable {
        case plain, timestamped, chaptered

        var title: String {
            switch self {
            case .plain: "本文のみ"
            case .timestamped: "時刻つき"
            case .chaptered: "チャプター見出しつき"
            }
        }
    }

    func text(_ format: Format, chapters: [Chapter] = []) -> String {
        switch format {
        case .plain:
            return sentences.map(\.text).joined(separator: "\n")
        case .timestamped:
            return sentences.map { "[\(TimeText.short($0.start))] \($0.text)" }.joined(separator: "\n")
        case .chaptered:
            var blocks: [[String]] = [[]]
            var remaining = chapters[...]
            for sentence in sentences {
                while let chapter = remaining.first, chapter.start <= sentence.start + 0.02 {
                    blocks.append(["■ \(TimeText.short(chapter.start)) \(chapter.title)"])
                    remaining.removeFirst()
                }
                blocks[blocks.count - 1].append(sentence.text)
            }
            return blocks.filter { !$0.isEmpty }.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
        }
    }
}
