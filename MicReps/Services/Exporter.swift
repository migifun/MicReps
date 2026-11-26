import AppKit
import Foundation
import UniformTypeIdentifiers

enum ExportKind: CaseIterable {
    case audio, text, timestampedText, markdown, subtitles, speakingReport

    var title: String {
        switch self {
        case .audio: "音声(m4a)…"
        case .text: "文字起こし(テキスト)…"
        case .timestampedText: "文字起こし(時刻つきテキスト)…"
        case .markdown: "文字起こし(チャプターつきMarkdown)…"
        case .subtitles: "字幕(SRT)…"
        case .speakingReport: "話し方の分析(Markdown)…"
        }
    }

    var needsTranscript: Bool { self != .audio }

    func fileExtension(audioFileName: String) -> String {
        switch self {
        case .audio: URL(filePath: audioFileName).pathExtension
        case .text, .timestampedText: "txt"
        case .markdown, .speakingReport: "md"
        case .subtitles: "srt"
        }
    }
}

enum Exporter {
    static func fileName(for title: String, extension ext: String) -> String {
        // ファイル名に使えない文字と、先頭の「.」(隠しファイルになる)を避ける。
        var name = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "録音" }
        // ファイル名の上限は255バイト。
        while name.utf8.count > 200 { name.removeLast() }
        return "\(name).\(ext)"
    }

    static func text(
        _ kind: ExportKind, title: String, createdAt: Date, duration: Double,
        transcript: Transcript, chapters: [Chapter]
    ) -> String? {
        switch kind {
        case .audio: nil
        case .text: transcript.text(.plain) + "\n"
        case .timestampedText: transcript.text(.timestamped) + "\n"
        case .markdown:
            markdown(title: title, createdAt: createdAt, duration: duration, transcript: transcript, chapters: chapters)
        case .subtitles: subtitles(transcript.sentences)
        case .speakingReport: nil
        }
    }

    private static func markdown(
        title: String, createdAt: Date, duration: Double, transcript: Transcript, chapters: [Chapter]
    ) -> String {
        let date = createdAt.formatted(
            .dateTime.year().month().day().hour().minute().locale(Locale(identifier: "ja_JP"))
        )
        var blocks = ["# \(title.replacingOccurrences(of: "\n", with: " "))", "\(date) / \(TimeText.short(duration))"]
        var body: [String] = []
        var remaining = chapters[...]
        func flush() {
            if !body.isEmpty { blocks.append(body.joined(separator: "\n")) }
            body = []
        }
        for sentence in transcript.sentences {
            while let chapter = remaining.first, chapter.start <= sentence.start + 0.02 {
                flush()
                blocks.append("## \(TimeText.short(chapter.start)) \(chapter.title)")
                remaining.removeFirst()
            }
            // 行末の空白2つで、1文ごとの改行を保つ。
            body.append(sentence.text + "  ")
        }
        flush()
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// 話し方の分析のまとめ。数値、口癖、指摘の一覧と言い直しの例。
    static func speakingReport(
        title: String, createdAt: Date, duration: Double, sentences: [Sentence],
        analysis: SpeakingAnalysis, review: SentenceReview?
    ) -> String {
        let date = createdAt.formatted(
            .dateTime.year().month().day().hour().minute().locale(Locale(identifier: "ja_JP"))
        )
        func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
        let pauses = analysis.spokenPauses
        var rows = [
            ("話した時間", TimeText.short(analysis.speakingTime)),
            ("フィラー", "\(analysis.fillers.count)回(1分に\(number(analysis.fillersPerMinute)))"),
            ("間", pauses.isEmpty ? "なし" : "\(pauses.count)回(平均\(number(pauses.map(\.length).reduce(0, +) / Double(pauses.count)))秒)"),
            ("長い文", "\(analysis.issues.count { $0.kind == .long })"),
            ("言い直し", "\(analysis.issues.count { $0.kind == .restart })"),
        ]
        if let rate = analysis.medianRate { rows.append(("話す速さ", "1秒に\(number(Double(rate)))音")) }
        if let pitch = analysis.medianPitch { rows.append(("声の高さ", "\(Int(pitch.rounded()))Hz")) }
        if let range = analysis.medianPitchRange { rows.append(("抑揚の幅", "\(number(Double(range)))半音")) }
        if let spread = analysis.volumeSpread { rows.append(("声の大きさの幅", "\(number(Double(spread)))dB")) }

        var blocks = [
            "# \(title.replacingOccurrences(of: "\n", with: " ")) 話し方の分析",
            "\(date) / \(TimeText.short(duration))",
            "## まとめ",
            (["| 項目 | 値 |", "|---|---|"] + rows.map { "| \($0.0) | \($0.1) |" }).joined(separator: "\n"),
        ]
        if !analysis.habits.isEmpty {
            blocks.append("## 口癖")
            blocks.append(analysis.habits.map { "- 「\($0.word)」\($0.count)回" }.joined(separator: "\n"))
        }
        let findings = analysis.findings(sentences, review: review)
        if !findings.isEmpty {
            blocks.append("## 指摘")
            var lines: [String] = []
            for finding in findings {
                lines.append("- \(TimeText.short(finding.time)) \(finding.kind.title): \(finding.detail)")
                if let rewrite = finding.rewrite {
                    lines.append("    - 言い直しの例(AI): \(rewrite.replacingOccurrences(of: "\n", with: " "))")
                }
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func subtitles(_ sentences: [Sentence]) -> String {
        sentences.enumerated().map { i, sentence in
            let next = i + 1 < sentences.count ? sentences[i + 1].start : .infinity
            // 次の字幕と重ならず、短すぎて読めないこともないようにする。
            let end = max(sentence.start + 0.1, min(max(sentence.end, sentence.start + 0.8), next))
            return "\(i + 1)\n\(stamp(sentence.start)) --> \(stamp(end))\n\(sentence.text)\n"
        }
        .joined(separator: "\n")
    }

    private static func stamp(_ seconds: Double) -> String {
        let total = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, total % 1000)
    }

    /// 上書きの確認は保存パネルが済ませている。途中で失敗しても、元からあったファイルは壊さない。
    static func copyAudio(from source: URL, to target: URL) throws {
        let files = FileManager.default
        guard source.standardizedFileURL != target.standardizedFileURL else { return }
        guard files.fileExists(atPath: target.path(percentEncoded: false)) else {
            try files.copyItem(at: source, to: target)
            return
        }
        let folder = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? files.removeItem(at: folder) }
        let copy = folder.appending(path: target.lastPathComponent)
        try files.copyItem(at: source, to: copy)
        _ = try files.replaceItemAt(target, withItemAt: copy)
    }
}
