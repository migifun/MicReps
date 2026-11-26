import SwiftUI

struct TranscriptPane: View {
    let model: AppModel
    let recording: Recording
    /// 読むモードの印。分析に使った文字起こしの文と並びが同じ。
    var marks: [SentenceMarks] = []
    @State private var transcript: Transcript?
    @AppStorage("transcriptMode") private var mode = Mode.reading

    enum Mode: String {
        /// 今のところを示し、押すと再生する。指摘の印も出す。
        case reading
        /// 文字を選んでコピーするための、飾りのない本文。
        case text
    }

    private var queue: ProcessingQueue { model.queue }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("文字起こし").font(.headline)
                if queue.isQueued(recording.id), hasText {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if hasText {
                    Picker("表示", selection: $mode) {
                        Text("読む").tag(Mode.reading)
                        Text("テキスト").tag(Mode.text)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("「読む」は押した文から再生し、指摘の印を出します。「テキスト」は文字を選んでコピーできます。")
                }
                if hasText { copyMenu }
            }
            if recording.transcriptState == .failed, hasText {
                problem(recording.transcriptMessage ?? "文字起こしに失敗しました。")
            }
            if recording.transcriptState == .needsModel, hasText { modelNeeded }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: cacheKey) { transcript = recording.transcript }
    }

    /// 内容が変わったときだけ読み込み直す。
    private var cacheKey: String { "\(recording.id)-\(recording.transcribedAt?.timeIntervalSince1970 ?? 0)" }

    private var hasText: Bool { recording.transcribedAt != nil && transcript?.sentences.isEmpty == false }

    @ViewBuilder
    private var content: some View {
        if let transcript, !transcript.sentences.isEmpty, recording.transcribedAt != nil {
            Group {
                switch mode {
                case .reading:
                    TranscriptReader(
                        model: model, sentences: transcript.sentences,
                        marks: marks.count == transcript.sentences.count ? marks : []
                    )
                case .text:
                    TranscriptTextView(sentences: transcript.sentences, currentIndex: nil, onSelect: nil)
                }
            }
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        } else if queue.currentID == recording.id {
            ProgressView(value: queue.progress) { Text("文字起こし中…") }
                .frame(maxWidth: 260)
        } else if queue.isQueued(recording.id) {
            ProgressView("順番を待っています…")
        } else {
            switch recording.transcriptState {
            case .needsModel: modelNeeded
            case .failed: problem(recording.transcriptMessage ?? "文字起こしに失敗しました。")
            case .noSpeech:
                VStack(spacing: 8) {
                    Text("音声が見つかりませんでした").foregroundStyle(.secondary)
                    retryButton
                }
            case .pending, .done: retryButton
            }
        }
    }

    private var modelNeeded: some View {
        VStack(spacing: 10) {
            Text("文字起こし用のデータ(Appleが提供)をこのMacにダウンロードする必要があります。")
                .multilineTextAlignment(.center)
            if queue.isInstallingModel {
                ProgressView("ダウンロード中…")
            } else {
                Button("ダウンロード") { Task { await queue.installModel() } }
            }
        }
    }

    private func problem(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            retryButton
        }
    }

    private var retryButton: some View {
        Button("文字起こしをする") { model.retranscribe(recording) }
            .disabled(recording.trashedAt != nil)
    }

    private var copyMenu: some View {
        Menu {
            ForEach(Transcript.Format.allCases, id: \.self) { format in
                Button(format.title) { model.copyTranscript(of: recording, format: format) }
            }
            Divider()
            Button("文字起こしをやり直す") { model.retranscribe(recording) }
                .disabled(queue.isQueued(recording.id) || recording.trashedAt != nil)
        } label: {
            Label(model.justCopied ? "コピーしました" : "全文をコピー",
                  systemImage: model.justCopied ? "checkmark" : "doc.on.doc")
        } primaryAction: {
            model.copyTranscript(of: recording, format: .plain)
        }
        .fixedSize()
    }
}
