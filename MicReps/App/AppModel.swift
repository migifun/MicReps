import AppKit
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let store: RecordingStore
    let recorder: RecorderService
    let player = PlayerService()
    let queue: ProcessingQueue
    let imports: ImportQueue

    static let localeKey = "transcriptionLocale"
    static let defaultLocale = "ja-JP"

    var selection: UUID?
    var searchText = ""
    var notices: [String] = []
    var showsPermissionAlert = false
    var renaming: Recording?
    var deleting: Recording?
    var editingChapter: ChapterEdit?
    var showsImporter = false
    var confirmsEmptyTrash = false
    var confirmingRegeneration: Recording?
    private(set) var justCopied = false

    @ObservationIgnored private let lock: InstanceLock
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?

    struct ChapterEdit: Identifiable {
        let recording: Recording
        let chapter: Chapter
        var id: UUID { chapter.id }
    }

    enum LaunchError: LocalizedError {
        case alreadyRunning
        var errorDescription: String? { "MicRepsはすでに起動しています。" }
    }

    init(paths: AppPaths, capture: AudioCapture, transcriber: Transcriber = AppleTranscriber(),
         generator: ChapterGenerator = AppleChapterGenerator(),
         reviewer: SentenceReviewer = AppleSentenceReviewer()) throws {
        try paths.createDirectories()
        guard let lock = InstanceLock(url: paths.lockFile) else { throw LaunchError.alreadyRunning }
        self.lock = lock
        container = try ModelContainer(
            for: Recording.self, configurations: ModelConfiguration(url: paths.database)
        )
        store = RecordingStore(paths: paths, container: container)
        recorder = RecorderService(
            store: store, capture: capture, freeSpace: { DiskSpace.available(at: paths.root) }
        )
        queue = ProcessingQueue(store: store, transcriber: transcriber, generator: generator, reviewer: reviewer) {
            Locale(identifier: UserDefaults.standard.string(forKey: Self.localeKey) ?? Self.defaultLocale)
        }
        imports = ImportQueue(store: store, freeSpace: { DiskSpace.available(at: paths.root) })
        imports.onNotice = { [weak self] in self?.notices.append($0) }
        imports.onImported = { [weak self] in self?.selection = $0.id }
        queue.onNotice = { [weak self] in self?.notices.append($0) }
        store.onReady = { [weak self] id in
            guard let self, self.store.recording(id)?.needsTranscription == true else { return }
            self.queue.enqueue(id)
        }
        recorder.onNotice = { [weak self] in self?.notices.append($0) }
        recorder.onPermissionDenied = { [weak self] in self?.showsPermissionAlert = true }
        recorder.onFinished = { [weak self] in self?.selection = $0.id }
    }

    func launch() {
        attempt {
            let recovered = try store.recover()
            try store.purgeExpiredTrash()
            try queue.enqueuePending()
            if recovered > 0 {
                notices.append("前回正しく終了しなかった録音を\(recovered)件復元しました。")
            }
            if selection == nil { selection = try store.all().first { $0.trashedAt == nil }?.id }
        }
        installKeyMonitor()
    }

    // MARK: - 録音

    func toggleRecording() {
        if recorder.isActive {
            recorder.finish()
        } else {
            player.pause()
            Task { await recorder.start() }
        }
    }

    func togglePause() {
        switch recorder.state {
        case .recording: recorder.pause()
        case .paused: recorder.resume()
        case .idle: break
        }
    }

    // MARK: - 再生

    var canPlay: Bool { !recorder.isActive && player.isLoaded }

    func showInPlayer(_ recording: Recording?) {
        guard let recording, recording.isSettled else {
            player.unload()
            return
        }
        player.load(id: recording.id, url: store.paths.audio(recording))
    }

    // MARK: - 一覧

    func attempt(_ work: () throws -> Void) {
        do { try work() } catch { notices.append(error.localizedDescription) }
    }

    func moveToTrash(_ recording: Recording) {
        attempt { try store.moveToTrash(recording) }
        if recording.trashedAt != nil { releaseIfSelected(recording) }
    }

    func deletePermanently(_ recording: Recording) {
        releaseIfSelected(recording)
        attempt { try store.deletePermanently(recording) }
    }

    func restore(_ recording: Recording) {
        attempt {
            try store.restore(recording)
            if recording.needsProcessing { queue.enqueue(recording.id) }
        }
    }

    func emptyTrash() {
        attempt {
            for recording in try store.all() where recording.trashedAt != nil { releaseIfSelected(recording) }
            try store.emptyTrash()
        }
    }

    private func releaseIfSelected(_ recording: Recording) {
        if player.loadedID == recording.id { player.unload() }
        if selection == recording.id { selection = nil }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 文字起こし

    var selectedRecording: Recording? { selection.flatMap { store.recording($0) } }

    func retranscribe(_ recording: Recording) {
        attempt { try queue.retry(recording) }
    }

    func copyTranscript(of recording: Recording, format: Transcript.Format) {
        guard let transcript = recording.transcript, !transcript.sentences.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.text(format, chapters: recording.chapters), forType: .string)
        justCopied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { self?.justCopied = false }
        }
    }

    // MARK: - 書き出し

    func canExport(_ kind: ExportKind, _ recording: Recording) -> Bool {
        recording.isSettled && (!kind.needsTranscript || !recording.transcriptText.isEmpty)
            && (kind != .speakingReport || recording.analysisState == .done)
    }

    func export(_ kind: ExportKind, _ recording: Recording) {
        guard canExport(kind, recording) else { return }
        let panel = NSSavePanel()
        let ext = kind.fileExtension(audioFileName: recording.audioFileName)
        panel.nameFieldStringValue = Exporter.fileName(for: recording.title, extension: ext)
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        let id = recording.id
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.write(kind, id, to: url)
        }
        if let window = NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// パネルを開いている間に削除されていることがあるので、取り直す。
    func write(_ kind: ExportKind, _ id: UUID, to url: URL) {
        attempt {
            guard let recording = store.recording(id) else { throw CocoaError(.fileNoSuchFile) }
            if kind == .audio {
                try Exporter.copyAudio(from: store.paths.audio(recording), to: url)
            } else if kind == .speakingReport {
                guard let analysis = recording.analysis, let transcript = recording.transcript else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let text = Exporter.speakingReport(
                    title: recording.title, createdAt: recording.createdAt, duration: recording.duration,
                    sentences: transcript.sentences, analysis: analysis, review: recording.review
                )
                try Data(text.utf8).write(to: url, options: .atomic)
            } else if let transcript = recording.transcript, let text = Exporter.text(
                kind, title: recording.title, createdAt: recording.createdAt, duration: recording.duration,
                transcript: transcript, chapters: recording.chapters
            ) {
                try Data(text.utf8).write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - チャプター

    /// 手を入れた章があるときだけ確認する。
    func requestChapterRegeneration(_ recording: Recording) {
        if recording.chapters.contains(where: \.isEdited) {
            confirmingRegeneration = recording
        } else {
            regenerateChapters(recording)
        }
    }

    func regenerateChapters(_ recording: Recording) {
        attempt { try queue.regenerateChapters(recording) }
    }

    func renameChapter(_ id: UUID, in recording: Recording, to title: String) {
        let title = ChapterBuilder.clean(title)
        guard !title.isEmpty else { return }
        editChapters(of: recording) { chapters in
            guard let index = chapters.firstIndex(where: { $0.id == id }), chapters[index].title != title else { return }
            chapters[index].title = title
            chapters[index].isEdited = true
        }
    }

    /// 削除した区間は前の章に含まれる。残った章も、作り直しで消えないよう編集済みとする。
    func deleteChapter(_ id: UUID, in recording: Recording) {
        editChapters(of: recording) { chapters in
            chapters.removeAll { $0.id == id }
            for index in chapters.indices { chapters[index].isEdited = true }
        }
    }

    private func editChapters(of recording: Recording, _ change: (inout [Chapter]) -> Void) {
        guard !queue.isQueued(recording.id) else {
            notices.append("処理が終わってから編集してください。")
            return
        }
        var chapters = recording.chapters
        let before = chapters
        change(&chapters)
        guard chapters != before else { return }
        attempt { try store.saveChapters(chapters, to: recording) }
    }

    @discardableResult
    func jumpToChapter(forward: Bool) -> Bool {
        guard canPlay, let chapters = selectedRecording?.chapters, !chapters.isEmpty else { return false }
        let time = player.currentPosition
        guard let target = forward
            ? Chapter.nextStart(from: time, in: chapters)
            : Chapter.previousStart(from: time, in: chapters)
        else { return false }
        player.seek(to: target)
        return true
    }

    // MARK: - キー操作

    /// スペースと矢印はメニューに登録すると文字入力まで奪うため、入力中でないときだけ拾う。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty || modifiers == .command,
              let window = event.window, window === NSApp.mainWindow, window.attachedSheet == nil,
              NSApp.modalWindow == nil, !Self.isTyping(window.firstResponder)
        else { return false }
        if modifiers == .command {
            switch event.keyCode {
            case 123: return jumpToChapter(forward: false)
            case 124: return jumpToChapter(forward: true)
            default: return false
            }
        }
        return handlePlaybackKey(event.keyCode)
    }

    /// 選択だけできる文字起こしの本文では、再生のキーを効かせる。
    static func isTyping(_ responder: NSResponder?) -> Bool {
        (responder as? NSText)?.isEditable ?? false
    }

    /// スペース・←・→。扱ったときだけ true。
    func handlePlaybackKey(_ code: UInt16) -> Bool {
        guard canPlay else { return false }
        switch code {
        case 49: player.togglePlay()
        case 123: player.skip(-PlayerService.skipInterval)
        case 124: player.skip(PlayerService.skipInterval)
        default: return false
        }
        return true
    }
}
