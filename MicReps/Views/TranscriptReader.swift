import SwiftUI

/// 読むモード。今話しているところを示し、押すとそこから再生する。フィラー・間・言い直しと文ごとの指摘を、本文の上に出す。
struct TranscriptReader: View {
    let model: AppModel
    let sentences: [Sentence]
    let marks: [SentenceMarks]

    @AppStorage("reader.showFillers") private var showFillers = true
    @AppStorage("reader.showPauses") private var showPauses = true
    @AppStorage("reader.showBadges") private var showBadges = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ReaderList(
                model: model, sentences: sentences, marks: marks,
                options: .init(fillers: showFillers, pauses: showPauses, badges: showBadges)
            )
            Menu {
                Toggle("フィラーと言い直し", isOn: $showFillers)
                Toggle("間(1秒以上)", isOn: $showPauses)
                Toggle("文ごとの指摘", isOn: $showBadges)
            } label: {
                Label("表示する印", systemImage: "line.3.horizontal.decrease.circle").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(8)
            .help("表示する印を選ぶ")
        }
    }
}

struct ReaderOptions: Equatable {
    var fillers: Bool
    var pauses: Bool
    var badges: Bool
}

/// 再生位置の更新(毎秒20回)で作り直されるのは、この範囲と今の文だけにする。
private struct ReaderList: View {
    let model: AppModel
    let sentences: [Sentence]
    let marks: [SentenceMarks]
    let options: ReaderOptions
    @State private var shownRewrite: String?

    private var currentIndex: Int? {
        model.player.hasStarted ? Transcript.index(at: model.player.position, in: sentences) : nil
    }

    var body: some View {
        let current = currentIndex
        let position = model.player.position
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sentences.indices, id: \.self) { index in
                        let isCurrent = index == current
                        ReaderRow(
                            sentence: sentences[index],
                            marks: marks.indices.contains(index) ? marks[index] : .init(),
                            options: options,
                            played: isCurrent ? TranscriptMarks.playedCount(in: sentences[index], at: position) : nil,
                            shownRewrite: $shownRewrite,
                            play: { model.player.play(from: sentences[index].start) }
                        )
                        .equatable()
                        .id(index)
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, 28)
            }
            .onChange(of: current) { _, index in
                // 再生中だけ追いかける。止めて読み返しているときは動かさない。
                guard let index, model.player.isPlaying else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(index, anchor: UnitPoint(x: 0, y: 0.3)) }
            }
        }
    }
}

private struct ReaderRow: View, @MainActor Equatable {
    let sentence: Sentence
    let marks: SentenceMarks
    let options: ReaderOptions
    /// 今の文なら、話し終えた文字数。
    let played: Int?
    @Binding var shownRewrite: String?
    let play: () -> Void

    static func == (a: ReaderRow, b: ReaderRow) -> Bool {
        a.sentence == b.sentence && a.marks == b.marks && a.options == b.options && a.played == b.played
            && a.shownRewrite == b.shownRewrite
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let chapter = marks.chapter {
                Text(chapter)
                    .font(.headline)
                    .padding(.top, 14)
                    .padding(.bottom, 2)
                    .padding(.leading, 52)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(TimeText.short(sentence.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(played != nil ? Color.accentColor : .secondary)
                    .frame(width: 42, alignment: .trailing)
                VStack(alignment: .leading, spacing: 5) {
                    Text(styledText)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if options.badges, !marks.badges.isEmpty { badges }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                played != nil ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 8)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: play)
            .help("ここから再生")

            if options.pauses, let pause = marks.pauseAfter, pause >= TranscriptMarks.minimumPause {
                Label(seconds(pause), systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .padding(.leading, 58)
                    .padding(.vertical, 1)
            }
        }
    }

    private func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1))))秒"
    }

    /// 本文に、話し終えたところ・フィラー・言い直し・文の途中の間を重ねる。
    private var styledText: AttributedString {
        let characters = Array(sentence.text)
        var pausesAt: [Int: Double] = [:]
        if options.pauses {
            for pause in marks.pauses { pausesAt[pause.offset] = pause.length }
        }
        var fillerAt = [SentenceMarks.Span?](repeating: nil, count: characters.count)
        var restartAt = [Bool](repeating: false, count: characters.count)
        if options.fillers {
            for span in marks.fillers {
                for i in span.offset..<min(characters.count, span.offset + span.length) where i >= 0 { fillerAt[i] = span }
            }
            for span in marks.restarts {
                for i in span.offset..<min(characters.count, span.offset + span.length) where i >= 0 { restartAt[i] = true }
            }
        }

        var result = AttributedString()
        var i = 0
        while i < characters.count {
            if let pause = pausesAt[i] {
                var chip = AttributedString(" ⏸\(seconds(pause)) ")
                chip.foregroundColor = .blue
                chip.font = .caption
                result += chip
            }
            // 同じ見た目が続く文字をまとめて足す。
            let isPlayed = played.map { i < $0 }
            let filler = fillerAt[i]
            let restart = restartAt[i]
            var j = i + 1
            while j < characters.count, pausesAt[j] == nil, fillerAt[j] == filler, restartAt[j] == restart,
                  played.map({ j < $0 }) == isPlayed {
                j += 1
            }
            var run = AttributedString(String(characters[i..<j]))
            if isPlayed == false { run.foregroundColor = .secondary }
            if let filler {
                run.backgroundColor = Color.yellow.opacity(filler.isCertain ? 0.45 : 0.25)
                run.foregroundColor = .brown
            }
            if restart {
                run.underlineStyle = .init(pattern: .solid, color: .brown)
                run.backgroundColor = Color.brown.opacity(0.15)
            }
            result += run
            i = j
        }
        return result
    }

    private var badges: some View {
        FlowLayout(spacing: 5) {
            ForEach(marks.badges) { badge in
                if let rewrite = badge.rewrite {
                    Button { shownRewrite = rewriteID(badge) } label: { chip(badge, showsRewrite: true) }
                        .buttonStyle(.plain)
                        .help("AIが作った言い直しの例を見る")
                        .popover(isPresented: Binding(
                            get: { shownRewrite == rewriteID(badge) },
                            set: { if !$0 { shownRewrite = nil } }
                        )) {
                            RewritePopover(original: sentence.text, rewrite: rewrite)
                        }
                } else {
                    chip(badge, showsRewrite: false)
                }
            }
        }
    }

    private func rewriteID(_ badge: SentenceMarks.Badge) -> String { "\(sentence.start)-\(badge.id)" }

    private func chip(_ badge: SentenceMarks.Badge, showsRewrite: Bool) -> some View {
        let color = SpeakingPane.color(badge.kind)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(badge.detail.isEmpty ? badge.kind.title : "\(badge.kind.title) \(badge.detail)")
            if showsRewrite {
                Image(systemName: "text.bubble").foregroundStyle(Color.accentColor)
            }
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: .capsule)
    }
}

/// 横に並べ、入りきらなければ折り返す。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
