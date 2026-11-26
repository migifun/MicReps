@preconcurrency import AVFAudio
import Foundation
import Speech

/// 文字起こしエンジン。精度が足りないときに別のものへ差し替えられるようにしている。
protocol Transcriber: Sendable {
    func transcribe(_ url: URL, locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TimedText]
    func installModel(for locale: Locale) async throws
    func supportedLocales() async -> [Locale]
}

enum TranscriberError: LocalizedError, Equatable {
    case unavailable, unsupportedLocale, needsModel

    var errorDescription: String? {
        switch self {
        case .unavailable: "このMacでは文字起こしを使えません。"
        case .unsupportedLocale: "この言語の文字起こしには対応していません。"
        case .needsModel: "文字起こし用のデータが必要です。"
        }
    }
}

struct AppleTranscriber: Transcriber {
    @concurrent
    func transcribe(
        _ url: URL, locale: Locale, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedText] {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.unsupportedLocale
        }
        do {
            return try await run(url, locale: locale, onProgress: onProgress)
        } catch {
            // 導入状態の表示は「未導入」でも動くことがあるため、失敗してから確かめる。
            let installed = await SpeechTranscriber.installedLocales
            if !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
                throw TranscriberError.needsModel
            }
            throw error
        }
    }

    private func run(
        _ url: URL, locale: Locale, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedText] {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        // fastResults を付けると、日本語での脱落が明らかに少ない(DESIGN.md 3章)。
        let transcriber = Self.makeTranscriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var pieces: [TimedText] = []
            for try await result in transcriber.results where result.isFinal {
                for run in result.text.runs {
                    pieces.append(TimedText(
                        text: String(result.text[run.range].characters),
                        start: run.audioTimeRange?.start.seconds,
                        end: run.audioTimeRange?.end.seconds
                    ))
                }
                if duration > 0 { onProgress(min(1, result.range.end.seconds / duration)) }
            }
            return pieces
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collector.value
    }

    func installModel(for locale: Locale) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.unsupportedLocale
        }
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [Self.makeTranscriber(locale)]
        ) {
            try await request.downloadAndInstall()
        }
    }

    func supportedLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.fastResults],
            attributeOptions: [.audioTimeRange]
        )
    }
}
