import Foundation

/// 長い文字起こしを区間に分けてAIに渡し、答えを検査して章にする。
/// AIの答えはそのまま信用しない。本文と照合できたものだけを使い、時刻は必ず本文から取る。
enum ChapterBuilder {
    static let windowCharacters = 2_500
    static let minimumSentences = 5
    static let minimumDuration = 45.0
    static let openingTitle = "はじめに"
    /// これより短い残りは、新しい章を探さない。
    private static let shortTail = 10

    struct Candidate: Equatable {
        var index: Int
        var title: String
    }

    static func isTooShort(_ sentences: [Sentence]) -> Bool {
        sentences.count < minimumSentences || (sentences.last?.end ?? 0) < minimumDuration
    }

    /// 1回の答えはばらつきが大きいので、聞き方を変えて3回聞く(DESIGN.md 4.3)。
    /// 並びは、位置と見出しを採用する優先順。
    private static let passes: [(question: ChapterQuestion, window: Int)] = [
        (.quote, 35), (.lineNumber, 35), (.lineNumber, 45),
    ]

    @MainActor
    static func build(
        _ sentences: [Sentence], locale: Locale, generator: ChapterGenerator,
        onProgress: (Double) -> Void
    ) async throws -> [Chapter] {
        let texts = sentences.map(\.text)
        var answers: [[Candidate]] = []
        var lastError: Error?
        for (number, pass) in passes.enumerated() {
            do {
                let found = try await ask(texts, pass.question, window: pass.window, locale: locale, generator: generator) {
                    onProgress((Double(number) + $0) / Double(passes.count))
                }
                answers.append(found)
            } catch let error as ChapterError where error == .refused || error == .tooLong {
                lastError = error
            }
        }
        guard !answers.isEmpty else { throw lastError ?? ChapterError.nothingFound }
        let agreed = merge(vote(answers, count: texts.count))
        guard !agreed.isEmpty else { throw ChapterError.nothingFound }
        return finish(agreed, sentences: sentences)
    }

    /// 区間を進めながら、ひととおり最後まで聞く。すべての区間で断られたときだけエラーにする。
    @MainActor
    private static func ask(
        _ texts: [String], _ question: ChapterQuestion, window: Int, locale: Locale,
        generator: ChapterGenerator, onProgress: (Double) -> Void
    ) async throws -> [Candidate] {
        var found: [Candidate] = []
        var start = 0
        var answered = false
        var lastError: Error?
        while start < texts.count {
            try Task.checkCancellation()
            var end = windowEnd(texts, from: start, limit: window)
            var proposals: [ChapterProposal] = []
            while true {
                do {
                    proposals = try await generator.propose(
                        Array(texts[start..<end]), firstLine: start, question: question, locale: locale
                    )
                    answered = true
                } catch ChapterError.tooLong where end - start > 4 {
                    end = start + (end - start) / 2
                    continue
                } catch let error as ChapterError where error == .refused || error == .tooLong {
                    // この区間だけ飛ばす。
                    lastError = error
                }
                break
            }
            var local = merge(locate(proposals, in: texts, range: start..<end))
            // 区間の先頭は、前の区間で見つけた章の頭か、前の章の続き。新しい章ではない。
            if start > 0 { local.removeAll { $0.index == start } }
            found += local
            onProgress(Double(end) / Double(texts.count))

            if let last = local.last, last.index - start >= 4 {
                // 最後の章は途中で切れているかもしれないので、その頭から見直す。
                if end == texts.count, texts.count - last.index < shortTail { break }
                start = last.index
            } else {
                start = end
            }
        }
        if !answered, let lastError { throw lastError }
        return snapToOpenings(merge(found), texts: texts)
    }

    /// 話題を切り出す言い回し。日本語のときだけ効く。
    private static let cues = ["続いて", "次に", "次は", "最後に", "さて", "それでは", "そういえば", "それから", "ところで", "話は変わ"]

    /// 章の頭を、話題を切り出している近くの文に合わせる。
    static func snapToOpenings(_ candidates: [Candidate], texts: [String]) -> [Candidate] {
        candidates.map { candidate in
            let index = candidate.index
            func opens(_ i: Int) -> Bool { cues.contains { texts[i].hasPrefix($0) } }
            guard index > 0, !opens(index) else { return candidate }
            if let near = [index - 1, index + 1, index - 2].first(where: { $0 > 0 && $0 < texts.count && opens($0) }) {
                return Candidate(index: near, title: candidate.title)
            }
            // 質問で切り出された話題は、答えではなく質問から始める。
            if index > 1, isQuestion(texts[index - 1]), !isQuestion(texts[index]) {
                return Candidate(index: index - 1, title: candidate.title)
            }
            return candidate
        }
    }

    /// 2つ以上の答えが(前後1文の差を許して)一致した所だけを選ぶ。
    static func vote(_ answers: [[Candidate]], count: Int) -> [Candidate] {
        guard count > 0 else { return [] }
        var votes = [Double](repeating: 0, count: count)
        for answer in answers {
            for index in Set(answer.map(\.index)) { votes[index] += 1 }
        }
        func score(_ i: Int) -> Double {
            votes[i] + 0.9 * ((i > 0 ? votes[i - 1] : 0) + (i + 1 < count ? votes[i + 1] : 0))
        }
        let needed = answers.count > 1 ? 1.8 : 0.9
        let ranked = votes.indices.filter { votes[$0] > 0 && score($0) >= needed }.sorted {
            (score($0), votes[$0], -$0) > (score($1), votes[$1], -$1)
        }
        var chosen: [Candidate] = []
        var taken = Set<Int>()
        for index in ranked where !taken.contains(index) {
            for answer in answers {
                let near = answer.filter { abs($0.index - index) <= 1 }
                if let best = near.min(by: { abs($0.index - index) < abs($1.index - index) }) {
                    chosen.append(best)
                    break
                }
            }
            for other in (index - 3)...(index + 3) { taken.insert(other) }
        }
        return chosen.sorted { $0.index < $1.index }
    }

    static func windowEnd(_ texts: [String], from start: Int, limit: Int) -> Int {
        var end = start
        var characters = 0
        while end < texts.count, end - start < limit {
            characters += texts[end].count
            if characters > windowCharacters, end > start { break }
            end += 1
        }
        return end
    }

    // MARK: - 照合

    /// AIの答えを本文の文に結びつける。結びつかない答えは捨てる。
    static func locate(_ proposals: [ChapterProposal], in texts: [String], range: Range<Int>) -> [Candidate] {
        var result: [Candidate] = []
        var lower = range.lowerBound
        for proposal in proposals {
            guard lower < range.upperBound else { break }
            let title = clean(proposal.title)
            guard !title.isEmpty else { continue }
            if let line = proposal.line {
                if range.contains(line) { result.append(Candidate(index: line, title: title)) }
                continue
            }
            let target = bigrams(proposal.firstSentence ?? "")
            guard !target.isEmpty else { continue }
            // 区間全体から最も近い文を選ぶ。それが前の章より手前なら逆順なので捨てる。
            // 残りだけから探すと、無関係な似た文に当ててしまう。
            var best = (index: lower, score: 0.0)
            for index in range {
                let candidate = bigrams(texts[index])
                let total = target.count + candidate.count
                let score = total == 0 ? 0 : 2 * Double(target.intersection(candidate).count) / Double(total)
                if score > best.score || (score == best.score && best.index < lower) { best = (index, score) }
            }
            guard best.score >= 0.6, best.index >= lower else { continue }
            result.append(Candidate(index: best.index, title: title))
            lower = best.index + 1
        }
        return result
    }

    /// 続けて同じような見出しが付いたものは1つの章とみなす。
    static func merge(_ candidates: [Candidate]) -> [Candidate] {
        var result: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.index < $1.index }) {
            if let last = result.last, last.index == candidate.index || isSimilar(last.title, candidate.title) { continue }
            result.append(candidate)
        }
        return result
    }

    static func isSimilar(_ a: String, _ b: String) -> Bool {
        if a.contains(b) || b.contains(a) { return true }
        let x = bigrams(a), y = bigrams(b)
        let smaller = min(x.count, y.count)
        return smaller > 0 && Double(x.intersection(y).count) / Double(smaller) >= 0.5
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let characters = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard characters.count > 1 else { return characters.isEmpty ? [] : [String(characters)] }
        return Set(zip(characters, characters.dropFirst()).map { String([$0, $1]) })
    }

    static func clean(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "「」『』\"。、")))
        return String(trimmed.replacingOccurrences(of: "\n", with: " ").prefix(40))
    }

    // MARK: - 仕上げ

    static func finish(_ candidates: [Candidate], sentences: [Sentence]) -> [Chapter] {
        let end = sentences.last?.end ?? 0
        var chapters = candidates.map { candidate in
            Chapter(start: sentences[candidate.index].start, title: candidate.title)
        }
        // 先頭の章は必ず0秒から。
        if candidates[0].index <= 3 || chapters[0].start < 15 {
            chapters[0].start = 0
        } else {
            chapters.insert(Chapter(start: 0, title: openingTitle), at: 0)
        }
        let minimum = min(45, max(12, end * 0.015))
        var kept: [Chapter] = []
        for chapter in chapters {
            if let last = kept.last, chapter.start - last.start < minimum || end - chapter.start < minimum / 2
                || isSimilar(last.title, chapter.title) { continue }
            kept.append(chapter)
        }
        return limit(kept, end: end)
    }

    /// 多すぎるときは、短い章から順に前の章へまとめる。
    static func limit(_ chapters: [Chapter], end: Double) -> [Chapter] {
        var result = chapters
        let maximum = max(20, Int(end / 90))
        while result.count > maximum {
            let shortest = (1..<result.count).min { length($0, result, end) < length($1, result, end) }!
            result.remove(at: shortest)
        }
        return result
    }

    private static func length(_ index: Int, _ chapters: [Chapter], _ end: Double) -> Double {
        (index + 1 < chapters.count ? chapters[index + 1].start : end) - chapters[index].start
    }

    private static func isQuestion(_ text: String) -> Bool {
        text.hasSuffix("か。") || text.hasSuffix("？") || text.hasSuffix("?")
    }
}
