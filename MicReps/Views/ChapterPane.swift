import SwiftUI

struct ChapterPane: View {
    let model: AppModel
    let recording: Recording
    @State private var chapters: [Chapter] = []

    private var isWorking: Bool {
        model.queue.isQueued(recording.id) && recording.chapterState == .pending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("チャプター").font(.headline)
                if isWorking, !chapters.isEmpty { ProgressView().controlSize(.small) }
                Spacer()
                if !chapters.isEmpty {
                    Menu {
                        Button("チャプターを作り直す…") { model.requestChapterRegeneration(recording) }
                            .disabled(model.queue.isQueued(recording.id) || recording.trashedAt != nil)
                    } label: {
                        Label("チャプターの操作", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            if [.failed, .unavailable].contains(recording.chapterState), !chapters.isEmpty {
                Text(recording.chapterMessage ?? "作り直しに失敗しました。").font(.caption).foregroundStyle(.orange)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: recording.chapterData, initial: true) { chapters = recording.chapters }
    }

    @ViewBuilder
    private var content: some View {
        if !chapters.isEmpty {
            ChapterList(model: model, recording: recording, chapters: chapters)
        } else if recording.transcriptState == .noSpeech {
            note("話し声が無いため、チャプターはありません。")
        } else if recording.transcribedAt == nil {
            note("文字起こしが終わると作られます。")
        } else if isWorking, model.queue.currentID == recording.id {
            ProgressView(value: model.queue.progress) { Text("作成中…") }
        } else if isWorking {
            note("順番を待っています…")
        } else {
            switch recording.chapterState {
            case .tooShort: note("短い録音のため、チャプターはありません。")
            case .unavailable, .failed:
                note(recording.chapterMessage ?? "チャプターを作れませんでした。")
                retry("もう一度試す")
            case .pending, .done: retry("チャプターを作る")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func retry(_ title: String) -> some View {
        Button(title) { model.requestChapterRegeneration(recording) }
            .disabled(recording.trashedAt != nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChapterList: View {
    let model: AppModel
    let recording: Recording
    let chapters: [Chapter]

    private var currentIndex: Int? {
        model.player.hasStarted ? Chapter.index(at: model.player.position, in: chapters) : nil
    }

    var body: some View {
        let current = currentIndex
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        row(chapter, isCurrent: index == current).id(chapter.id)
                    }
                }
            }
            .onChange(of: current) { _, new in
                if let new, chapters.indices.contains(new) { withAnimation { proxy.scrollTo(chapters[new].id) } }
            }
        }
    }

    private func row(_ chapter: Chapter, isCurrent: Bool) -> some View {
        Button { model.player.play(from: chapter.start) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(TimeText.short(chapter.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(chapter.title).fontWeight(isCurrent ? .semibold : .regular).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isCurrent ? Color.accentColor.opacity(0.22) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chapter.title)、\(TimeText.short(chapter.start))")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .contextMenu {
            Button("名前を変更…") { model.editingChapter = .init(recording: recording, chapter: chapter) }
            Button("このチャプターを削除", role: .destructive) {
                model.deleteChapter(chapter.id, in: recording)
            }
        }
    }
}
