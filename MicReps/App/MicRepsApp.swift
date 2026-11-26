import AppKit
import SwiftData
import SwiftUI

@main
struct MicRepsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("MicReps", id: "main") {
            if let model = delegate.model {
                MainView(model: model)
                    .modelContainer(model.container)
            } else {
                ContentUnavailableView(
                    "MicRepsを開けませんでした", systemImage: "exclamationmark.triangle",
                    description: Text(delegate.launchError ?? "")
                )
                .frame(minWidth: 500, minHeight: 300)
            }
        }
        .defaultSize(width: 1040, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                if let model = delegate.model {
                    Button("音声・動画を取り込む…") { model.showsImporter = true }
                        .keyboardShortcut("o")
                    Divider()
                    ExportMenu(model: model)
                }
            }
            if let model = delegate.model {
                RecordingCommands(model: model)
            }
            TextEditingCommands()
        }
        Window("振り返り", id: "trends") {
            if let model = delegate.model {
                TrendsView(model: model)
                    .modelContainer(model.container)
            }
        }
        .defaultSize(width: 900, height: 720)
        Settings {
            if let model = delegate.model { SettingsView(model: model) }
        }
    }
}

/// 選んでいる録音の書き出し。
struct ExportMenu: View {
    let model: AppModel

    var body: some View {
        Menu("書き出す") {
            if let recording = model.selectedRecording {
                ExportButtons(model: model, recording: recording)
            }
        }
        .disabled(model.recorder.isActive || model.selection == nil)
    }
}

struct ExportButtons: View {
    let model: AppModel
    let recording: Recording

    var body: some View {
        ForEach(ExportKind.allCases, id: \.self) { kind in
            Button(kind.title) { model.export(kind, recording) }
                .disabled(!model.canExport(kind, recording))
        }
    }
}

struct RecordingCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("録音") {
            Button(model.recorder.isActive ? "録音を完了" : "録音を開始") { model.toggleRecording() }
                .keyboardShortcut("r")
            Button(model.recorder.state == .paused ? "録音を再開" : "録音を一時停止") { model.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.recorder.isActive)
            Divider()
            Button("文字起こしの全文をコピー") {
                if let recording = model.selectedRecording { model.copyTranscript(of: recording, format: .plain) }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.recorder.isActive || model.selection == nil)
            Divider()
            TrendsButton()
        }
        CommandMenu("再生") {
            Button(model.player.isPlaying ? "一時停止(スペース)" : "再生(スペース)") { model.player.togglePlay() }
                .disabled(!model.canPlay)
            Button("15秒戻る(←)") { model.player.skip(-PlayerService.skipInterval) }
                .disabled(!model.canPlay)
            Button("15秒進む(→)") { model.player.skip(PlayerService.skipInterval) }
                .disabled(!model.canPlay)
            Divider()
            Button("前のチャプター(⌘←)") { model.jumpToChapter(forward: false) }
                .disabled(!model.canPlay)
            Button("次のチャプター(⌘→)") { model.jumpToChapter(forward: true) }
                .disabled(!model.canPlay)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel?
    private(set) var launchError: String?

    override init() {
        super.init()
        do {
            model = try Self.makeModel()
        } catch {
            launchError = error.localizedDescription
        }
    }

    private static func makeModel() throws -> AppModel {
        #if DEBUG
        // 単体テストの土台として起動されたときは、本物の録音に触れない。
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let root = FileManager.default.temporaryDirectory.appending(path: "MicRepsTestHost-\(UUID().uuidString)")
            return try AppModel(paths: AppPaths(root: root), capture: SyntheticCapture())
        }
        if UserDefaults.standard.bool(forKey: "MRSynthetic") {
            return try AppModel(paths: try migratedStandard(), capture: SyntheticCapture())
        }
        #endif
        return try AppModel(paths: try migratedStandard(), capture: MicrophoneCapture())
    }

    /// 旧名 VoiceRec のときの録音と設定を引き継いでから使う。
    private static func migratedStandard() throws -> AppPaths {
        let paths = AppPaths.standard
        if ProcessInfo.processInfo.environment["MICREPS_HOME"] == nil {
            try LegacyMigration.moveData(from: AppPaths.legacyStandard, to: paths)
            LegacyMigration.copySettings(from: LegacyMigration.legacyDefaultsDomain)
        }
        return paths
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model?.launch()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "MRAutoRecord") { model?.toggleRecording() }
        #endif
    }

    /// Finderの「このアプリケーションで開く」やDockへのドロップ。
    func application(_ application: NSApplication, open urls: [URL]) {
        model?.imports.add(urls)
    }

    /// 録音中にウィンドウを閉じても録音を続ける。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        model == nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.recorder.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "録音中です"
        alert.informativeText = "終了すると、ここまでの録音を保存します。"
        alert.addButton(withTitle: "保存して終了")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        guard let task = model.recorder.finish() else { return .terminateNow }
        Task {
            await task.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// 振り返りの窓を開く。
struct TrendsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("振り返り", systemImage: "chart.line.uptrend.xyaxis") { openWindow(id: "trends") }
            .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}
