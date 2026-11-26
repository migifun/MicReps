import Foundation

/// 文字起こしからフィラーと口癖を探す。
enum FillerDetector {
    private struct Rule {
        var pattern: Regex<Substring>
        /// 前後に関係なくフィラーとみなすか。
        var isCertain: Bool
    }

    /// 上から順に当てはめ、先に当たった範囲は後の規則で数えない。
    nonisolated(unsafe) private static let rules: [Rule] = [
        Rule(pattern: /え[ーっ]*と[ーぉ]*/, isCertain: true),
        Rule(pattern: /えー+/, isCertain: true),
        Rule(pattern: /あー+/, isCertain: true),
        Rule(pattern: /うー+ん|んー+/, isCertain: true),
        Rule(pattern: /まあ+っ?と?|まぁ/, isCertain: true),
        // 指示語(「あの家」など)と区別できないので、前後から推定する。
        Rule(pattern: /あのー+|そのー+/, isCertain: true),
        Rule(pattern: /あの|その/, isCertain: false),
        Rule(pattern: /なんか/, isCertain: false),
        Rule(pattern: /こう(?=、)/, isCertain: false),
        Rule(pattern: /うん(?=、)/, isCertain: false),
    ]

    /// 推定のフィラーとして数える、前に来る語。
    private static let leadIns = ["実際", "まあ", "えと", "えっと", "で", "なんか", "あの", "その"]
    /// 推定のフィラーとして数える、後に続く語。
    private static let followers = ["あの", "その", "えと", "えっと", "えー", "まあ", "実際"]
    private static let boundaries: Set<Character> = ["、", "。", "？", "！", " "]
    /// これ以上次の文字まで空いていれば、言葉の切れ目とみなす(秒)。
    static let gap = 0.5

    static func fillers(in sentences: [Sentence]) -> [SpeakingAnalysis.Filler] {
        var result: [SpeakingAnalysis.Filler] = []
        for (index, sentence) in sentences.enumerated() {
            let text = sentence.text
            let characters = Array(text)
            var taken = [Bool](repeating: false, count: characters.count)
            var found: [SpeakingAnalysis.Filler] = []

            for rule in rules {
                for match in text.matches(of: rule.pattern) {
                    let offset = text.distance(from: text.startIndex, to: match.range.lowerBound)
                    let length = text.distance(from: match.range.lowerBound, to: match.range.upperBound)
                    guard length > 0, !taken[offset..<offset + length].contains(true) else { continue }
                    guard rule.isCertain || isSeparated(characters, sentence, offset: offset, length: length)
                    else { continue }
                    for i in offset..<offset + length { taken[i] = true }
                    found.append(.init(
                        sentence: index, offset: offset, length: length, time: sentence.time(at: offset),
                        word: String(match.output), isCertain: rule.isCertain
                    ))
                }
            }
            // 文頭の「で、」「で。」はつなぎの言葉として数える。
            if characters.count >= 2, characters[0] == "で", boundaries.contains(characters[1]), !taken[0] {
                found.append(.init(sentence: index, offset: 0, length: 1, time: sentence.start, word: "で", isCertain: false))
            }
            result += found.sorted { $0.offset < $1.offset }
        }
        return result
    }

    /// 推定の語が、前後から見て言葉の切れ目に挟まれているか。
    private static func isSeparated(_ characters: [Character], _ sentence: Sentence, offset: Int, length: Int) -> Bool {
        let end = offset + length
        let before = offset == 0 ? nil : characters[offset - 1]
        let after = end < characters.count ? characters[end] : nil
        if after == nil || boundaries.contains(after!) { return true }
        if before == nil || boundaries.contains(before!) { return true }
        let preceding = String(characters[max(0, offset - 3)..<offset])
        if leadIns.contains(where: { preceding.hasSuffix($0) }) { return true }
        // 「なんかその」のように、すぐ後にもつなぎの言葉が続く。
        let following = String(characters[end..<min(characters.count, end + 3)])
        if followers.contains(where: { following.hasPrefix($0) }) { return true }
        if sentence.times != nil, end < characters.count, sentence.time(at: end) - sentence.time(at: end - 1) >= gap {
            return true
        }
        return false
    }

    /// 口癖になりやすい言葉。
    static let habitWords = [
        "っていう", "実際", "本当に", "ほんとに", "やっぱり", "やっぱ", "ちゃんと", "結構", "基本的に", "一応",
        "とりあえず", "みたいな", "的な", "要は", "逆に", "正直", "すごい", "めっちゃ", "ですね", "感じで", "形で",
    ]
    static let habitMinimum = 3

    static func habits(in sentences: [Sentence]) -> [SpeakingAnalysis.Habit] {
        let text = sentences.map(\.text).joined(separator: "\n")
        var counts: [String: Int] = [:]
        for word in habitWords {
            counts[word] = text.ranges(of: word).count
        }
        // 「やっぱり」の中の「やっぱ」を二重に数えない。
        counts["やっぱ", default: 0] -= counts["やっぱり"] ?? 0
        return counts.filter { $0.value >= habitMinimum }
            .map { SpeakingAnalysis.Habit(word: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }
    }
}

/// 日本語の読みがなから音の数(モーラ)を数える。
enum MoraCounter {
    private static let small: Set<Character> = ["ゃ", "ゅ", "ょ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゎ"]

    static func count(_ text: String) -> Int {
        let reading = hiragana(text)
        return reading.filter { character in
            guard let scalar = character.unicodeScalars.first?.value else { return false }
            return (0x3041...0x3096).contains(scalar) && !small.contains(character) || character == "ー"
        }.count
    }

    static func hiragana(_ text: String) -> String {
        let string = text as CFString
        let length = CFStringGetLength(string)
        guard length > 0, let tokenizer = CFStringTokenizerCreate(
            nil, string, CFRangeMake(0, length), kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale
        ) else { return "" }
        var latin = ""
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            if let reading = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription
            ) as? String {
                latin += reading + " "
            }
        }
        let output = NSMutableString(string: latin)
        CFStringTransform(output, nil, kCFStringTransformLatinHiragana, false)
        return output as String
    }
}
