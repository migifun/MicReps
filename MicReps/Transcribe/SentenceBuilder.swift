import Foundation

/// 文字起こしの最小単位。1文字から数文字で、時刻が付かないこともある。
struct TimedText: Equatable, Sendable {
    var text: String
    var start: Double?
    var end: Double?
}

/// 時刻つきの断片を文に組み直す。
/// 基本は句読点で切る。句読点が出ないときに備えて、間の長さと文字数でも切る。
enum SentenceBuilder {
    static let longPause = 3.0
    static let pause = 1.0
    static let pauseMinimumLength = 40
    static let softLimit = 80
    static let hardLimit = 120

    private struct Unit {
        var character: Character
        var start: Double
        var end: Double
    }

    private static let terminators: Set<Character> = ["。", "？", "！", "?", "!"]
    private static let closers: Set<Character> = ["」", "』", "）", ")", "”", "\"", "’"]

    static func build(_ pieces: [TimedText]) -> [Sentence] {
        let units = expand(pieces)
        var result: [Sentence] = []
        var current: [Unit] = []

        func flush() {
            defer { current = [] }
            let kept = tidy(current)
            let text = String(kept.map(\.character))
            let times = kept.map { ($0.start * 100).rounded() / 100 }
            guard !text.isEmpty, let first = current.first(where: { !$0.character.isWhitespace }) else { return }
            // 句読点だけの切れ端は、前の文の一部として扱う。
            if text.allSatisfy({ $0.isPunctuation || $0.isSymbol }), !result.isEmpty {
                result[result.count - 1].text += text
                result[result.count - 1].times? += times
                return
            }
            result.append(Sentence(
                start: first.start, end: max(first.start, current.last!.end), text: text, times: times
            ))
        }

        for (i, unit) in units.enumerated() {
            if let last = current.last {
                let gap = unit.start - last.end
                if gap >= longPause || (gap >= pause && current.count >= pauseMinimumLength) { flush() }
            }
            current.append(unit)

            let next = i + 1 < units.count ? units[i + 1].character : nil
            // 「。」の後に続く閉じかっこや重なった記号までを1文にする。
            if let next, terminators.contains(next) || closers.contains(next) { continue }
            if endsSentence(current, next: next)
                || current.count >= hardLimit
                || (current.count >= softLimit && unit.character == "、") {
                flush()
            }
        }
        flush()
        return result
    }

    private static func endsSentence(_ units: [Unit], next: Character?) -> Bool {
        guard let last = units.last(where: { !closers.contains($0.character) })?.character else { return false }
        if terminators.contains(last) { return true }
        // 英文のピリオド。「3.5」のような数字の途中では切らない。
        return last == "." && (next == nil || next!.isWhitespace)
    }

    private static func expand(_ pieces: [TimedText]) -> [Unit] {
        var units: [Unit] = []
        var clock = 0.0
        for piece in pieces where !piece.text.isEmpty {
            let start = max(clock, piece.start ?? clock)
            let end = max(start, piece.end ?? start)
            let step = (end - start) / Double(piece.text.count)
            for (i, character) in piece.text.enumerated() {
                units.append(Unit(
                    character: character.isNewline ? " " : character,
                    start: start + step * Double(i), end: start + step * Double(i + 1)
                ))
            }
            clock = end
        }
        return units
    }

    /// 日本語と数字の間などに入る余分な空白を取る。英単語どうしの空白は残す。
    static func tidy(_ text: String) -> String {
        String(tidy(text.map { Unit(character: $0, start: 0, end: 0) }).map(\.character))
    }

    /// 文字と時刻の組のまま空白を取る。残した文字と時刻がずれないようにするため。
    private static func tidy(_ units: [Unit]) -> [Unit] {
        guard let from = units.firstIndex(where: { !$0.character.isWhitespace }),
              let to = units.lastIndex(where: { !$0.character.isWhitespace }) else { return [] }
        let units = Array(units[from...to])
        var output: [Unit] = []
        for (i, unit) in units.enumerated() {
            if unit.character.isWhitespace {
                guard let before = output.last?.character, !before.isWhitespace, !isJapanese(before),
                      let after = units[(i + 1)...].first(where: { !$0.character.isWhitespace })?.character,
                      !isJapanese(after)
                else { continue }
                output.append(Unit(character: " ", start: unit.start, end: unit.end))
            } else {
                output.append(unit)
            }
        }
        return output
    }

    private static func isJapanese(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x3000...0x30FF).contains(scalar)   // 句読点・かな
            || (0x3400...0x9FFF).contains(scalar)   // 漢字
            || (0xF900...0xFAFF).contains(scalar)
            || (0xFF00...0xFFEF).contains(scalar)   // 全角記号
    }
}
