import Foundation
import FoundationModels

/// 章の始まりの答えさせ方。
enum ChapterQuestion: Sendable {
    /// 行番号で答える。余分な章が少ないが、番号がずれることがある。
    case lineNumber
    /// 最初の文を書き写す。位置は正確だが、章が多めになる。
    case quote
}

struct ChapterProposal: Equatable, Sendable {
    var title: String
    var line: Int?
    var firstSentence: String?
}

enum ChapterError: LocalizedError, Equatable {
    case unavailable(String)
    case tooLong
    case refused
    case nothingFound

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .tooLong: "文章が長すぎて処理できませんでした。"
        case .refused: "この内容からはチャプターを作れませんでした。"
        case .nothingFound: "チャプターを作れませんでした。"
        }
    }
}

/// 文の並びから章の候補を出すAI。差し替えられるようにしている。
protocol ChapterGenerator: Sendable {
    /// 使えない理由。使えるなら nil。
    func unavailableReason(for locale: Locale) -> String?
    /// firstLine は先頭の文の行番号(録音全体での通し番号)。
    func propose(
        _ sentences: [String], firstLine: Int, question: ChapterQuestion, locale: Locale
    ) async throws -> [ChapterProposal]
}

struct AppleChapterGenerator: ChapterGenerator {
    @Generable
    struct NumberedItem {
        @Guide(description: "章が始まる行番号")
        var line: Int
        @Guide(description: "章の見出し。15文字以内")
        var title: String
    }

    @Generable
    struct NumberedItems {
        @Guide(description: "話題ごとの章。行番号の昇順", .maximumCount(6))
        var chapters: [NumberedItem]
    }

    // 見出しを先に書かせると、その話題を切り出した文を正しく選びやすい。
    @Generable
    struct QuotedItem {
        @Guide(description: "章の見出し。15文字以内")
        var title: String
        @Guide(description: "その話題を切り出している最初の文。文字起こしからそのまま書き写す")
        var firstSentence: String
    }

    @Generable
    struct QuotedItems {
        @Guide(description: "話題ごとの章。出てくる順", .maximumCount(6))
        var chapters: [QuotedItem]
    }

    func unavailableReason(for locale: Locale) -> String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(locale) ? nil : "この言語のチャプター作成には対応していません。"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "チャプターを作るには、システム設定でApple Intelligenceをオンにしてください。"
        case .unavailable(.modelNotReady):
            return "Apple Intelligenceの準備中です。しばらくしてからもう一度試してください。"
        case .unavailable:
            return "このMacではチャプターを作れません。"
        }
    }

    @concurrent
    func propose(
        _ sentences: [String], firstLine: Int, question: ChapterQuestion, locale: Locale
    ) async throws -> [ChapterProposal] {
        var instructions = switch question {
        case .lineNumber:
            "あなたは録音の文字起こしを話題ごとの章に分ける編集者です。各行の先頭は行番号です。話題が変わる最初の行だけを章の始まりに選び、短い見出しを付けます。"
        case .quote:
            "あなたは録音の文字起こしを話題ごとの章に分ける編集者です。1行が1文です。話題が変わるところだけで章を分け、短い見出しを付けます。"
        }
        if locale.language.languageCode?.identifier != "ja",
           let name = Locale(identifier: "ja").localizedString(forIdentifier: locale.identifier) {
            instructions += "見出しは\(name)で書きます。"
        }
        // 毎回まっさらな状態で聞く。前の会話が残ると長さの上限に達してしまう。
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(sampling: .greedy)
        do {
            switch question {
            case .lineNumber:
                let prompt = sentences.enumerated().map { "\($0.offset + firstLine): \($0.element)" }.joined(separator: "\n")
                return try await session.respond(to: prompt, generating: NumberedItems.self, options: options)
                    .content.chapters.map { ChapterProposal(title: $0.title, line: $0.line) }
            case .quote:
                let prompt = sentences.joined(separator: "\n")
                return try await session.respond(to: prompt, generating: QuotedItems.self, options: options)
                    .content.chapters.map { ChapterProposal(title: $0.title, firstSentence: $0.firstSentence) }
            }
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw ChapterError.tooLong
            case .guardrailViolation, .refusal, .decodingFailure: throw ChapterError.refused
            case .assetsUnavailable: throw ChapterError.unavailable("Apple Intelligenceの準備中です。しばらくしてからもう一度試してください。")
            default: throw error
            }
        }
    }
}
