import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    let recordings: [Recording]
    @State private var trashExpanded = false

    private func matches(_ recording: Recording) -> Bool {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || recording.title.localizedStandardContains(query)
            || recording.transcriptText.localizedStandardContains(query)
    }

    private var active: [Recording] {
        recordings.filter { $0.trashedAt == nil && $0.state != .recording && matches($0) }
    }

    private var trashed: [Recording] {
        recordings.filter { $0.trashedAt != nil && matches($0) }
    }

    var body: some View {
        List(selection: $model.selection) {
            ForEach(active) { recording in
                RecordingRow(recording: recording)
                    .tag(recording.id)
                    .badge(model.queue.currentID == recording.id ? Text("文字起こし中") : nil)
                    .contextMenu { actions(for: recording) }
            }
            if !trashed.isEmpty {
                Section("最近削除した項目", isExpanded: $trashExpanded) {
                    ForEach(trashed) { recording in
                        RecordingRow(recording: recording)
                            .tag(recording.id)
                            .contextMenu { trashActions(for: recording) }
                    }
                }
            }
        }
        .disabled(model.recorder.isActive)
        .onDeleteCommand(perform: deleteSelected)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "名前と文字起こしを検索")
        .overlay {
            if active.isEmpty, trashed.isEmpty {
                if model.searchText.isEmpty {
                    ContentUnavailableView("録音はまだありません", systemImage: "mic")
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
            if let name = model.imports.currentName {
                ProgressView(value: model.imports.progress) {
                    Text(model.imports.waiting.isEmpty ? "取り込み中: \(name)" : "取り込み中: \(name)(ほか\(model.imports.waiting.count)件)")
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            TrendsButton()
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("録音ごとの話し方の変化を見る(⌘⇧T)")
            Button { model.toggleRecording() } label: {
                Label(
                    model.recorder.isActive ? "録音を完了" : "録音",
                    systemImage: model.recorder.isActive ? "stop.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func actions(for recording: Recording) -> some View {
        Button("名前を変更…") { model.renaming = recording }
        Button("Finderで表示") {
            NSWorkspace.shared.activateFileViewerSelecting([model.store.paths.audio(recording)])
        }
        Menu("書き出す") { ExportButtons(model: model, recording: recording) }
        Divider()
        Button("削除", role: .destructive) { model.moveToTrash(recording) }
            .disabled(!recording.isSettled)
    }

    @ViewBuilder
    private func trashActions(for recording: Recording) -> some View {
        Button("元に戻す") { model.restore(recording) }
        Divider()
        Button("完全に削除…", role: .destructive) { model.deleting = recording }
        Button("すべて完全に削除…", role: .destructive) { model.confirmsEmptyTrash = true }
    }

    private func deleteSelected() {
        guard let recording = recordings.first(where: { $0.id == model.selection }) else { return }
        if recording.trashedAt == nil {
            model.moveToTrash(recording)
        } else {
            model.deleting = recording
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recording.title).fontWeight(.medium).lineLimit(1)
            HStack {
                Text(recording.createdAt, format: .dateTime.month().day().hour().minute())
                Spacer()
                switch recording.state {
                case .ready: Text(TimeText.short(recording.duration)).monospacedDigit()
                case .failed: Label("保存に失敗", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                case .converting, .recording: Text("保存中…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
