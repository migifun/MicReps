import Foundation
import NaturalLanguage

/// 句点までをひとつにまとめた「話した文」。文字起こしの文は、読みやすさのために間や文字数でも切っているため。
struct SpokenSentence: Equatable, Sendable {
    /// 文字起こしの文の番号(最初と最後)。
    var first: Int
    var last: Int
    var start: Double
    var end: Double
    /// フィラーを除いた本文。
    var text: String

    static let terminators: Set<Character> = ["。", "？", "！", "?", "!"]

    static func build(_ sentences: [Sentence], fillers: [SpeakingAnalysis.Filler]) -> [SpokenSentence] {
        var result: [SpokenSentence] = []
        var current: SpokenSentence?
        for (index, sentence) in sentences.enumerated() {
            let text = removing(fillers.filter { $0.sentence == index }, from: sentence.text)
            if var spoken = current {
                spoken.last = index
                spoken.end = sentence.end
                spoken.text += text
                current = spoken
            } else {
                current = SpokenSentence(first: index, last: index, start: sentence.start, end: sentence.end, text: text)
            }
            if let last = sentence.text.last(where: { !$0.isWhitespace }), terminators.contains(last) {
                result.append(current!)
                current = nil
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// フィラーと、その直後の読点を取り除く。
    static func removing(_ fillers: [SpeakingAnalysis.Filler], from text: String) -> String {
        var characters = Array(text)
        for filler in fillers.sorted(by: { $0.offset > $1.offset }) {
            var end = filler.offset + filler.length
            guard filler.offset >= 0, end <= characters.count else { continue }
            if end < characters.count, characters[end] == "、" { end += 1 }
            characters.removeSubrange(filler.offset..<end)
        }
        return String(characters)
    }

    /// 句読点を除いた文字数。
    var length: Int { text.filter { !$0.isPunctuation && !$0.isWhitespace }.count }
    var commas: Int { text.filter { $0 == "、" }.count }
    var duration: Double { end - start }
}

/// 文の長さ、修飾の重なり、言い直しを、決まりに沿って見つける。
enum SentenceRules {
    static let longLength = 80
    static let veryLongLength = 120
    static let longDuration = 20.0
    /// 「〜な、〜い、〜した」のように、名詞を飾る言葉が読点で続く数。
    static let modifierChain = 3

    static func issues(_ spoken: [SpokenSentence]) -> [SpeakingAnalysis.SentenceIssue] {
        var result: [SpeakingAnalysis.SentenceIssue] = []
        for sentence in spoken {
            if sentence.length >= longLength || sentence.duration >= longDuration {
                let level = sentence.length >= veryLongLength ? "とても長い " : ""
                result.append(.init(
                    kind: .long, sentence: sentence.first, time: sentence.start,
                    detail: "\(level)\(sentence.length)字・\(Int(sentence.duration.rounded()))秒・読点\(sentence.commas)"
                ))
            }
            let chain = modifiers(in: sentence.text)
            if chain >= modifierChain {
                result.append(.init(
                    kind: .modifiers, sentence: sentence.first, time: sentence.start,
                    detail: "飾る言葉が\(chain)つ続く"
                ))
            }
            for phrase in restarts(in: sentence.text) {
                result.append(.init(kind: .restart, sentence: sentence.first, time: sentence.start, detail: "「\(phrase)」"))
            }
        }
        return result
    }

    nonisolated(unsafe) private static let modifierEnding = /(な|い|た|だ|る|の|という|っていう|ような|みたいな)$/

    /// 読点で区切った部分が、名詞を飾る形で続く最大の数。
    static func modifiers(in text: String) -> Int {
        let parts = text.split(separator: "、", omittingEmptySubsequences: false).dropLast()
        var best = 0
        var current = 0
        for part in parts {
            if part.contains(modifierEnding) {
                current += 1
                best = max(best, current)
            } else {
                current = 0
            }
        }
        return best
    }

    /// 繰り返しても言い直しとみなさない語(口癖やよく使う語)。
    private static let ordinary: Set<String> = [
        "実際", "っていう", "その", "あの", "まあ", "こと", "もの", "ところ", "それ", "これ", "する", "して",
        "ない", "ある", "いう", "って", "です", "ます", "よう", "本当に", "ちゃんと",
    ]

    /// 「資料の中資料たちの中」「時間によって時間によって」のような言い直し。
    static func restarts(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.japanese)
        let words = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        var found: [Range<String.Index>] = []

        // 2〜4語のまとまりが、そのまま続けて繰り返される(「時間によって時間によって」)。
        for size in 2...4 {
            for i in words.indices where i + 2 * size <= words.count {
                let first = words[i..<i + size].map { String(text[$0]) }.joined()
                let second = words[(i + size)..<(i + 2 * size)].map { String(text[$0]) }.joined()
                if first == second, first.count >= 3 {
                    found.append(words[i].lowerBound..<words[i + 2 * size - 1].upperBound)
                }
            }
        }
        // 同じ語(2文字以上)が、読点を挟まずに3語以内でまた出てくる。
        for i in words.indices {
            let word = String(text[words[i]])
            guard word.count >= 2, !ordinary.contains(word), !word.contains(where: \.isPunctuation) else { continue }
            for j in (i + 1)..<min(words.count, i + 4) where String(text[words[j]]) == word {
                // 「アプリやスマホアプリ」のように並べただけのものは除く。
                let between = text[words[i].upperBound..<words[j].lowerBound]
                guard !between.contains("、"), !between.contains(where: { "やとかも".contains($0) }) else { continue }
                found.append(words[i].lowerBound..<words[j].upperBound)
                break
            }
        }
        // 重なったものは、まとめて1つにする。
        var merged: [Range<String.Index>] = []
        for range in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound < last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged.map { String(text[$0]) }
    }
}
