import SwiftUI

/// 話し方の分析。数値のまとめと、押すとその場所から再生する指摘の一覧。
struct SpeakingPane: View {
    let model: AppModel
    let recording: Recording
    let analysis: SpeakingAnalysis?
    let review: SentenceReview?
    let sentences: [Sentence]
    @State private var kind: SpeakingAnalysis.FindingKind?
    @State private var shownRewrite: String?

    private var isWorking: Bool {
        model.queue.isQueued(recording.id) && recording.analysisState == .pending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("話し方").font(.headline)
                if isWorking, analysis != nil { ProgressView().controlSize(.small) }
                Spacer()
                if analysis != nil {
                    Menu {
                        Button("分析し直す") { try? model.queue.reanalyze(recording) }
                            .disabled(model.queue.isQueued(recording.id) || recording.trashedAt != nil)
                        Button("文を見直し直す") { try? model.queue.rereview(recording) }
                            .disabled(model.queue.isQueued(recording.id) || recording.trashedAt != nil
                                || recording.analysisState != .done)
                    } label: {
                        Label("分析の操作", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let analysis {
            VStack(alignment: .leading, spacing: 8) {
                summary(analysis)
                Divider()
                reviewStatus
                findings(analysis)
            }
        } else if recording.transcriptState == .noSpeech {
            note("話し声が無いため、分析はありません。")
        } else if recording.transcribedAt == nil {
            note("文字起こしが終わると分析します。")
        } else if isWorking, model.queue.currentID == recording.id {
            ProgressView(value: model.queue.progress) { Text("分析中…") }
        } else if isWorking {
            note("順番を待っています…")
        } else {
            if recording.analysisState == .failed {
                note(recording.analysisMessage ?? "分析できませんでした。")
            }
            Button("分析する") { try? model.queue.reanalyze(recording) }
                .disabled(recording.trashedAt != nil)
        }
    }

    /// AIによる文の見直し(脱線と言い直しの例)の状態。時間がかかるので、ほかの結果とは別に出す。
    @ViewBuilder
    private var reviewStatus: some View {
        let isReviewing = model.queue.isQueued(recording.id) && recording.reviewState == .pending
        if isReviewing, model.queue.currentID == recording.id, recording.analysisState == .done,
           recording.chapterState != .pending {
            ProgressView(value: model.queue.progress) { Text("文を見直し中…").font(.caption) }
        } else if isReviewing {
            Text("文の見直しを待っています…").font(.caption).foregroundStyle(.secondary)
        } else if [.failed, .unavailable].contains(recording.reviewState) {
            HStack {
                Text(recording.reviewMessage ?? "文を見直せませんでした。").font(.caption).foregroundStyle(.orange)
                Button("もう一度") { try? model.queue.rereview(recording) }
                    .controlSize(.small)
                    .disabled(recording.trashedAt != nil)
            }
        } else if let review, review.skipped > 0 {
            Text("\(review.skipped)文はAIが見直せませんでした。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private func summary(_ analysis: SpeakingAnalysis) -> some View {
        let pauses = analysis.spokenPauses
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            row("話した時間", TimeText.short(analysis.speakingTime))
            row("フィラー", "\(analysis.fillers.count)回(1分に\(analysis.fillersPerMinute.formatted(.number.precision(.fractionLength(1)))))")
            row("間", pauses.isEmpty ? "なし" : "\(pauses.count)回(平均\(seconds(pauses.map(\.length).reduce(0, +) / Double(pauses.count))))")
            if let rate = analysis.medianRate {
                row("話す速さ", "1秒に\(Double(rate).formatted(.number.precision(.fractionLength(1))))音")
            }
            if let pitch = analysis.medianPitch {
                row("声の高さ", "\(Int(pitch.rounded()))Hz")
            }
            if let range = analysis.medianPitchRange {
                row("抑揚の幅", "\(Double(range).formatted(.number.precision(.fractionLength(1))))半音")
            }
            if let spread = analysis.volumeSpread {
                row("大きさの幅", "\(Double(spread).formatted(.number.precision(.fractionLength(1))))dB")
            }
            if !analysis.habits.isEmpty {
                GridRow(alignment: .top) {
                    Text("口癖").foregroundStyle(.secondary)
                    Text(analysis.habits.prefix(5).map { "「\($0.word)」\($0.count)" }.joined(separator: " "))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .help("抑揚の幅は文の中の声の高さの幅、大きさの幅は文ごとの声の大きさのばらつきです。")
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1))))秒"
    }

    private func findings(_ analysis: SpeakingAnalysis) -> some View {
        let all = analysis.findings(sentences, review: review)
        let shown = kind.map { kind in all.filter { $0.kind == kind } } ?? all
        let kinds = SpeakingAnalysis.FindingKind.allCases.filter { kind in all.contains { $0.kind == kind } }
        return VStack(alignment: .leading, spacing: 6) {
            Picker("表示", selection: $kind) {
                Text("すべて(\(all.count))").tag(SpeakingAnalysis.FindingKind?.none)
                ForEach(kinds, id: \.self) { kind in
                    Text("\(kind.title)(\(all.filter { $0.kind == kind }.count))").tag(Optional(kind))
                }
            }
            .labelsHidden()
            .fixedSize()
            if shown.isEmpty {
                note("気になるところは見つかりませんでした。")
            } else {
                List(shown) { finding in
                    VStack(alignment: .leading, spacing: 2) {
                        Button {
                            model.player.play(from: max(0, finding.time - 0.3))
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(TimeText.short(finding.time)).monospacedDigit().foregroundStyle(.secondary)
                                Circle().fill(Self.color(finding.kind)).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(finding.kind.title)
                                    Text(finding.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("ここから再生")
                        if let rewrite = finding.rewrite {
                            Button("言い直しの例を見る", systemImage: "text.bubble") { shownRewrite = finding.id }
                                .font(.caption)
                                .buttonStyle(.link)
                                .padding(.leading, 54)
                                .popover(isPresented: Binding(
                                    get: { shownRewrite == finding.id },
                                    set: { if !$0 { shownRewrite = nil } }
                                )) {
                                    RewritePopover(original: sentenceText(finding), rewrite: rewrite)
                                }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    /// 指摘した話した文の全文(フィラーを含む文字起こしのまま)。
    private func sentenceText(_ finding: SpeakingAnalysis.Finding) -> String {
        guard let first = finding.sentence, sentences.indices.contains(first) else { return "" }
        var text = ""
        for sentence in sentences[first...] {
            text += sentence.text
            if let last = sentence.text.last, SpokenSentence.terminators.contains(last) { break }
        }
        return text
    }

    static func color(_ kind: SpeakingAnalysis.FindingKind) -> Color {
        switch kind {
        case .longSentence: .red
        case .modifiers: .teal
        case .restart: .brown
        case .offTopic: .indigo
        case .filler: .yellow
        case .longPause, .silence: .blue
        case .monotone: .purple
        case .weakEnding: .orange
        case .fast, .slow: .green
        }
    }
}

/// 元の文と、AIによる言い直しの例。言い直しは選んでコピーできる。
struct RewritePopover: View {
    let original: String
    let rewrite: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("話した文").font(.caption).foregroundStyle(.secondary)
            Text(original).textSelection(.enabled)
            Divider()
            Text("言い直しの例(AI)").font(.caption).foregroundStyle(.secondary)
            Text(rewrite).textSelection(.enabled)
            Text("AIが作った例です。意味が変わっていないか確かめてください。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 波形の下に出す、声の高さ(線)と大きさ(塗り)のグラフ。
struct VoiceGraph: View {
    let analysis: SpeakingAnalysis
    let position: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let duration = analysis.duration
                let volume = analysis.volumeContour
                guard duration > 0, !volume.isEmpty else { return }
                let step = size.width / CGFloat(volume.count)
                let floor = analysis.silenceThreshold
                let top = max(floor + 1, volume.max() ?? floor)
                var area = Path()
                area.move(to: CGPoint(x: 0, y: size.height))
                for (i, level) in volume.enumerated() {
                    let value = CGFloat(max(0, min(1, (level - floor) / (top - floor))))
                    area.addLine(to: CGPoint(x: CGFloat(i) * step, y: size.height * (1 - value * 0.9)))
                }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                context.fill(area, with: .color(.secondary.opacity(0.18)))

                // 声の高さは中央値から±8半音を上下いっぱいに描く。
                var line = Path()
                var drawing = false
                let contour = analysis.pitchContour
                for i in contour.indices {
                    // 細かな揺れで読みにくくならないよう、前後と平均する。
                    let near = contour[max(0, i - 2)...min(contour.count - 1, i + 2)].compactMap { $0 }
                    guard contour[i] != nil, !near.isEmpty else { drawing = false; continue }
                    let pitch = near.reduce(0, +) / Float(near.count)
                    let y = size.height * (0.5 - CGFloat(max(-8, min(8, pitch))) / 16)
                    let point = CGPoint(x: (CGFloat(i) + 0.5) * step, y: y)
                    if drawing { line.addLine(to: point) } else { line.move(to: point) }
                    drawing = true
                }
                context.stroke(line, with: .color(.pink.opacity(0.8)), lineWidth: 1.2)

                let x = size.width * position / duration
                context.fill(Path(CGRect(x: min(x, size.width - 1.5), y: 0, width: 1.5, height: size.height)),
                             with: .color(.accentColor))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard proxy.size.width > 0 else { return }
                seek(analysis.duration * value.location.x / proxy.size.width)
            })
        }
        .help("線は声の高さ、灰色は声の大きさです。")
    }
}
