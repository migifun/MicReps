import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Bindable var model: AppModel
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]

    private var selected: Recording? {
        recordings.first { $0.id == model.selection }
    }

    /// 選択の切り替えと、変換完了によるファイルの変化の両方で読み込み直す。
    private var playerKey: String {
        guard let selected else { return "" }
        return "\(selected.id)-\(selected.stateRaw)-\(selected.audioFileName)"
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, recordings: recordings)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
                .frame(minWidth: 580, minHeight: 400)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.imports.add(urls)
            return !urls.isEmpty
        }
        .fileImporter(
            isPresented: $model.showsImporter, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): model.imports.add(urls)
            case .failure(let error): model.notices.append(error.localizedDescription)
            }
        }
        .alert("最近削除した項目を空にしますか?", isPresented: $model.confirmsEmptyTrash) {
            Button("すべて削除", role: .destructive) { model.emptyTrash() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("\(recordings.count { $0.trashedAt != nil })件の音声を完全に削除します。元に戻せません。")
        }
        .onChange(of: playerKey, initial: true) { model.showInPlayer(selected) }
        .alert("お知らせ", isPresented: hasNotice) {
            Button("OK") {}
        } message: {
            Text(model.notices.first ?? "")
        }
        .alert("マイクを使えません", isPresented: $model.showsPermissionAlert) {
            Button("設定を開く") { model.openMicrophoneSettings() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("録音するには、システム設定の「プライバシーとセキュリティ」>「マイク」でMicRepsを許可してください。")
        }
        .alert("完全に削除しますか?", isPresented: isPresent($model.deleting), presenting: model.deleting) { recording in
            Button("削除", role: .destructive) { model.deletePermanently(recording) }
            Button("キャンセル", role: .cancel) {}
        } message: { recording in
            Text("「\(recording.title)」の音声を削除します。元に戻せません。")
        }
        .alert("チャプターを作り直しますか?", isPresented: isPresent($model.confirmingRegeneration),
               presenting: model.confirmingRegeneration) { recording in
            Button("作り直す", role: .destructive) { model.regenerateChapters(recording) }
            Button("キャンセル", role: .cancel) {}
        } message: { _ in
            Text("変更した名前や削除した内容は失われます。")
        }
        .sheet(item: $model.renaming) { recording in
            RenameSheet(original: recording.title) { title in
                model.attempt { try model.store.rename(recording, to: title) }
            }
        }
        .sheet(item: $model.editingChapter) { edit in
            RenameSheet(original: edit.chapter.title) { title in
                model.renameChapter(edit.chapter.id, in: edit.recording, to: title)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.recorder.isActive {
            RecorderView(model: model)
        } else if let selected {
            PlayerView(model: model, recording: selected)
        } else {
            ContentUnavailableView(
                "録音を選んでください", systemImage: "waveform",
                description: Text("左下の録音ボタンか ⌘R で、新しい録音を始められます。")
            )
            .navigationTitle("MicReps")
        }
    }

    private var hasNotice: Binding<Bool> {
        Binding(
            get: { !model.notices.isEmpty },
            set: { if !$0, !model.notices.isEmpty { model.notices.removeFirst() } }
        )
    }

    private func isPresent(_ item: Binding<Recording?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

private struct RenameSheet: View {
    let original: String
    let onSave: (String) -> Void
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("名前を変更").font(.headline)
            TextField("名前", text: $title)
                .frame(width: 300)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("変更", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { title = original }
    }

    private func save() {
        onSave(title)
        dismiss()
    }
}
