import Foundation
import FoundationModels

/// AIによる文の見直し。本題から外れた文と、長い文の言い直しの例。
struct SentenceReview: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Self.currentVersion
    /// 本題から外れていると判定した、話した文の最初の文字起こしの文の番号。
    var offTopic: [Int]
    var rewrites: [Rewrite]
    /// AIが答えなかった(内容の制限などで)文の数。
    var skipped: Int

    struct Rewrite: Codable, Equatable, Sendable {
        var sentence: Int
        var text: String
    }
}

enum SentenceRole: Sendable {
    case main, detail, appeal, aside
}

enum ReviewError: LocalizedError, Equatable {
    case unavailable(String)
    case refused

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .refused: "この文は見直せませんでした。"
        }
    }
}

/// 文を見直すAI。差し替えられるようにしている。
protocol SentenceReviewer: Sendable {
    func unavailableReason(for locale: Locale) -> String?
    /// topic はその部分の話題(章の見出し)。
    func role(of sentence: String, topic: String) async throws -> SentenceRole
    func rewrite(_ sentence: String) async throws -> String
}

enum SentenceReviewBuilder {
    /// これより短い文は、脱線かどうかを聞かない(相づちや切り出しが多いため)。
    static let minimumLength = 10

    /// 脱線は章の見出しを話題として判定する。章が無ければ判定しない。
    static func build(
        _ spoken: [SpokenSentence], issues: [SpeakingAnalysis.SentenceIssue], chapters: [Chapter],
        reviewer: SentenceReviewer, onProgress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> SentenceReview {
        let rewriteTargets = Set(issues.filter { $0.kind == .long || $0.kind == .modifiers }.map(\.sentence))
        let total = Double(max(1, spoken.count))
        var review = SentenceReview(offTopic: [], rewrites: [], skipped: 0)
        var answered = 0
        for (i, sentence) in spoken.enumerated() {
            try Task.checkCancellation()
            if !chapters.isEmpty, sentence.length >= minimumLength,
               let topic = chapters.last(where: { $0.start <= sentence.start + 0.5 })?.title ?? chapters.first?.title {
                do {
                    if try await reviewer.role(of: sentence.text, topic: topic) == .aside {
                        review.offTopic.append(sentence.first)
                    }
                    answered += 1
                } catch ReviewError.refused {
                    review.skipped += 1
                }
            }
            if rewriteTargets.contains(sentence.first) {
                do {
                    let text = try await reviewer.rewrite(sentence.text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { review.rewrites.append(.init(sentence: sentence.first, text: text)) }
                    answered += 1
                } catch ReviewError.refused {
                    review.skipped += 1
                }
            }
            onProgress(Double(i + 1) / total)
        }
        // 1つも答えられなかったのは、AIが使えない状態とみなす。
        if answered == 0, review.skipped > 0 { throw ReviewError.refused }
        return review
    }
}

struct AppleSentenceReviewer: SentenceReviewer {
    @Generable
    enum Role {
        case 本題の説明, 補足や具体例, 聞き手への呼びかけ, 本題と無関係な雑談
    }

    @Generable
    struct RoleAnswer {
        var role: Role
    }

    @Generable
    struct RewriteAnswer {
        @Guide(description: "意味を変えずに、聞き手に分かりやすく言い直した文。短い文に分けてもよい")
        var rewrite: String
    }

    func unavailableReason(for locale: Locale) -> String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(locale) ? nil : "この言語の文の見直しには対応していません。"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "文を見直すには、システム設定でApple Intelligenceをオンにしてください。"
        case .unavailable(.modelNotReady):
            return "Apple Intelligenceの準備中です。しばらくしてからもう一度試してください。"
        case .unavailable:
            return "このMacでは文の見直しを使えません。"
        }
    }

    @concurrent
    func role(of sentence: String, topic: String) async throws -> SentenceRole {
        let answer = try await ask(
            "あなたは話し方の先生です。プレゼンの中の1文が、どんな役割かを選びます。",
            "この部分の話題: \(topic)\n文: \(sentence)", RoleAnswer.self
        )
        return switch answer.role {
        case .本題の説明: .main
        case .補足や具体例: .detail
        case .聞き手への呼びかけ: .appeal
        case .本題と無関係な雑談: .aside
        }
    }

    @concurrent
    func rewrite(_ sentence: String) async throws -> String {
        try await ask(
            "あなたは話し方の先生です。プレゼンで話した文を、聞き手に分かりやすく言い直します。",
            sentence, RewriteAnswer.self
        ).rewrite
    }

    /// 毎回まっさらな状態で聞く。話題によっては内容の制限に掛かりやすいため、変換向けの緩い設定を使う。
    private func ask<T: Generable>(_ instructions: String, _ prompt: String, _ type: T.Type) async throws -> T {
        let session = LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: instructions
        )
        do {
            return try await session.respond(to: prompt, generating: type, options: .init(sampling: .greedy)).content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal, .decodingFailure, .exceededContextWindowSize: throw ReviewError.refused
            case .assetsUnavailable: throw ReviewError.unavailable("Apple Intelligenceの準備中です。しばらくしてからもう一度試してください。")
            default: throw error
            }
        }
    }
}
