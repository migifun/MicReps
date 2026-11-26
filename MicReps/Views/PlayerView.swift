import SwiftUI

struct PlayerView: View {
    let model: AppModel
    let recording: Recording
    /// 再生中は毎秒20回描き直すので、章の位置は変わったときだけ読み出す。
    @State private var marks: [Double] = []
    @State private var analysis: SpeakingAnalysis?
    @State private var review: SentenceReview?
    @State private var chapters: [Chapter] = []
    @State private var readerMarks: [SentenceMarks] = []
    @State private var sentences: [Sentence] = []
    @AppStorage("sidePane") private var side = SidePane.chapters

    enum SidePane: String {
        case chapters, speaking
    }

    private var showsSpeaking: Bool { side == .speaking }

    private var player: PlayerService { model.player }

    var body: some View {
        VStack(spacing: 14) {
            header
            switch recording.state {
            case .recording, .converting:
                Spacer()
                ProgressView("保存中…")
                Spacer()
            case .ready, .failed:
                if recording.state == .failed { failure }
                if let error = player.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                HStack(alignment: .top, spacing: 16) {
                    TranscriptPane(model: model, recording: recording, marks: readerMarks)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("表示", selection: $side) {
                            Text("チャプター").tag(SidePane.chapters)
                            Text("話し方").tag(SidePane.speaking)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if showsSpeaking {
                            SpeakingPane(
                                model: model, recording: recording, analysis: analysis, review: review, sentences: sentences
                            )
                        } else {
                            ChapterPane(model: model, recording: recording)
                        }
                    }
                    .frame(width: showsSpeaking ? 250 : 190)
                }
                .id(recording.id)
                PlaybackWaveform(
                    samples: recording.waveform, marks: marks, position: player.position, duration: player.duration,
                    fillers: showsSpeaking ? analysis?.fillers.map(\.time) ?? [] : [],
                    pauses: showsSpeaking ? analysis?.pauses.filter { $0.length >= 1 } ?? [] : [],
                    seek: { player.seek(to: $0) }
                )
                .frame(height: 52)
                .accessibilityHidden(true)
                if showsSpeaking, let analysis {
                    VoiceGraph(analysis: analysis, position: player.position, seek: { player.seek(to: $0) })
                        .frame(height: 30)
                        .accessibilityHidden(true)
                }
                controls.disabled(!player.isLoaded)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(recording.title)
        .onChange(of: recording.chapterData, initial: true) {
            chapters = recording.chapters
            marks = chapters.map(\.start)
        }
        .onChange(of: MarkInputs(sentences: sentences, analysis: analysis, review: review, chapters: chapters), initial: true) {
            readerMarks = TranscriptMarks.build(sentences, analysis: analysis, review: review, chapters: chapters)
        }
        .task(id: "\(recording.id)-\(recording.analyzedAt?.timeIntervalSince1970 ?? 0)") {
            // 分析に使った文字起こしと並びを合わせるため、両方を同時に読み直す。
            analysis = recording.analysis
            sentences = recording.transcript?.sentences ?? []
        }
        .onChange(of: recording.reviewData, initial: true) { review = recording.review }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recording.title).font(.title2.weight(.semibold)).lineLimit(2)
                Button("名前を変更", systemImage: "pencil") { model.renaming = recording }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("名前を変更")
                Spacer()
                if recording.trashedAt != nil {
                    Button("元に戻す") { model.restore(recording) }
                }
            }
            HStack(spacing: 8) {
                Text(recording.createdAt, format: .dateTime.year().month().day().hour().minute())
                if recording.wasRecovered { Label("復元", systemImage: "arrow.counterclockwise") }
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failure: some View {
        HStack {
            Label(recording.failureMessage ?? "保存に失敗しました。", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Spacer()
            Button("やり直す") {
                player.unload()
                model.store.beginFinalizing(recording)
            }
        }
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }

    private var controls: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.1)
            ) { Text("再生位置") }
                .labelsHidden()
            HStack {
                Text(TimeText.short(player.position))
                Spacer()
                Text("-" + TimeText.short(player.duration.rounded(.down) - player.position.rounded(.down)))
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)

            ZStack {
                HStack(spacing: 28) {
                    Button("15秒戻る", systemImage: "gobackward.15") { player.skip(-PlayerService.skipInterval) }
                        .font(.title2)
                    Button(player.isPlaying ? "一時停止" : "再生",
                           systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.togglePlay() }
                        .font(.largeTitle)
                        .frame(width: 44)
                    Button("15秒進む", systemImage: "goforward.15") { player.skip(PlayerService.skipInterval) }
                        .font(.title2)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)

                HStack {
                    Spacer()
                    Picker("速度", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                        ForEach(PlayerService.rates, id: \.self) { Text("\($0.formatted())x").tag($0) }
                    }
                    .fixedSize()
                }
            }
        }
    }
}

private struct PlaybackWaveform: View {
    let samples: [Float]
    /// 章の区切り。
    let marks: [Double]
    let position: Double
    let duration: Double
    var fillers: [Double] = []
    var pauses: [SpeakingAnalysis.Pause] = []
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard !samples.isEmpty, duration > 0 else { return }
                let count = max(1, min(samples.count, Int(size.width / 4)))
                let step = size.width / CGFloat(count)
                let progress = position / duration
                for i in 0..<count {
                    let lower = i * samples.count / count
                    let upper = max(lower + 1, (i + 1) * samples.count / count)
                    let level = samples[lower..<min(upper, samples.count)].max() ?? 0
                    let played = (Double(i) + 0.5) / Double(count) <= progress
                    context.fill(
                        WaveformBar.path(level, x: CGFloat(i) * step, width: step * 0.62, height: size.height),
                        with: .color(played ? .accentColor : .secondary.opacity(0.45))
                    )
                }
                for pause in pauses {
                    let x = size.width * pause.start / duration
                    let width = max(1, size.width * pause.length / duration)
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                                 with: .color(.blue.opacity(0.18)))
                }
                for filler in fillers {
                    let x = size.width * filler / duration
                    var tick = Path()
                    tick.move(to: CGPoint(x: x - 3, y: 0))
                    tick.addLine(to: CGPoint(x: x + 3, y: 0))
                    tick.addLine(to: CGPoint(x: x, y: 6))
                    tick.closeSubpath()
                    context.fill(tick, with: .color(.yellow))
                }
                for mark in marks where mark > 0 {
                    let x = size.width * mark / duration
                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                                 with: .color(.primary.opacity(0.35)))
                }
                let x = size.width * progress
                context.fill(Path(CGRect(x: min(x, size.width - 1.5), y: 0, width: 1.5, height: size.height)),
                             with: .color(.accentColor))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard proxy.size.width > 0 else { return }
                seek(duration * value.location.x / proxy.size.width)
            })
        }
    }
}

/// 読むモードの印を作り直す条件。
private struct MarkInputs: Equatable {
    var sentences: [Sentence]
    var analysis: SpeakingAnalysis?
    var review: SentenceReview?
    var chapters: [Chapter]
}
