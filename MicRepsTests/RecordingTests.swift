import AVFAudio
import Foundation
import SwiftData
import Testing
@testable import MicReps

@MainActor
struct RecorderTests {
    let paths: AppPaths
    let store: RecordingStore
    let capture = FakeCapture()
    let recorder: RecorderService

    init() throws {
        paths = try makePaths()
        store = try makeStore(paths)
        recorder = RecorderService(store: store, capture: capture, freeSpace: { 50_000_000_000 })
    }

    @Test func 録音して完了するとm4aになりCAFは消える() async throws {
        await recorder.start()
        #expect(recorder.state == .recording)
        capture.onBuffer?(tone(seconds: 2))
        await recorder.finish()?.value
        let recording = try #require(try store.all().first)
        #expect(recording.state == .ready)
        #expect(abs(recording.duration - 2) < 0.01)
        #expect(exists(paths.m4a(recording.id)))
        #expect(!exists(paths.caf(recording.id)))
        #expect(recorder.state == .idle)
        #expect(!recording.waveform.isEmpty)
    }

    @Test func 一時停止中の音は入らず再開すると続きから録る() async throws {
        await recorder.start()
        capture.onBuffer?(tone(seconds: 1))
        let first = capture.onBuffer
        recorder.pause()
        #expect(recorder.state == .paused)
        #expect(capture.onBuffer == nil)
        #expect(first != nil)
        recorder.resume()
        capture.onBuffer?(tone(seconds: 1))
        await recorder.finish()?.value
        let recording = try #require(try store.all().first)
        #expect(abs(recording.duration - 2) < 0.01)
    }

    @Test func 一時停止のまま完了できる() async throws {
        await recorder.start()
        capture.onBuffer?(tone(seconds: 1))
        recorder.pause()
        await recorder.finish()?.value
        #expect(try store.all().first?.state == .ready)
    }

    @Test func 音が無ければ何も残さない() async throws {
        await recorder.start()
        #expect(recorder.finish() == nil)
        #expect(try store.all().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.recordings.path(percentEncoded: false)).isEmpty)
    }

    @Test func 許可が無ければ始めない() async throws {
        capture.permission = false
        var denied = false
        recorder.onPermissionDenied = { denied = true }
        await recorder.start()
        #expect(denied)
        #expect(recorder.state == .idle)
        #expect(try store.all().isEmpty)
    }

    @Test func マイクを開けなければ残骸を残さない() async throws {
        capture.startError = CaptureError.noInput
        await recorder.start()
        #expect(recorder.state == .idle)
        #expect(try store.all().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.recordings.path(percentEncoded: false)).isEmpty)
    }

    @Test func 続けて押しても録音は一つだけ() async throws {
        async let a: Void = recorder.start()
        async let b: Void = recorder.start()
        _ = await (a, b)
        #expect(try store.all().count == 1)
        #expect(capture.starts == 1)
    }

    @Test func マイクが変わると一時停止して知らせる() async throws {
        var notices: [String] = []
        recorder.onNotice = { notices.append($0) }
        await recorder.start()
        capture.onBuffer?(tone(seconds: 1))
        capture.onInterruption?(.deviceChanged)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.state == .paused)
        #expect(notices.count == 1)
        recorder.resume()
        capture.onBuffer?(tone(rate: 16_000, seconds: 1))
        await recorder.finish()?.value
        let recording = try #require(try store.all().first)
        #expect(abs(recording.duration - 2) < 0.05)
    }

    @Test func 同じマイクの設定変更では録音を続けるが繰り返すと止める() async throws {
        await recorder.start()
        // 再開の処理は内部で50ミリ秒待つので、それより十分長く待つ(負荷が高いと間に合わないことがあった)。
        capture.onInterruption?(.configurationChanged)
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.state == .recording)
        #expect(capture.starts == 2)
        for _ in 0..<3 {
            capture.onInterruption?(.configurationChanged)
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(recorder.state == .paused)
    }

    @Test func 停止後に遅れて届いた割り込みは無視する() async throws {
        await recorder.start()
        let late = capture.onInterruption
        recorder.pause()
        recorder.resume()
        late?(.deviceChanged)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.state == .recording)
    }

    @Test func 容量が減ると一度だけ警告し足りなくなると保存して終える() async throws {
        var notices: [String] = []
        recorder.onNotice = { notices.append($0) }
        await recorder.start()
        capture.onBuffer?(tone(seconds: 1))
        recorder.checkSpace(900_000_000)
        recorder.checkSpace(800_000_000)
        #expect(notices.count == 1)
        #expect(recorder.state == .recording)
        recorder.checkSpace(100_000_000)
        #expect(recorder.state == .idle)
        for task in store.finalizations.values { await task.value }
        #expect(try store.all().first?.state == .ready)
    }

    @Test func 無音が続くと知らせ音が入ると消える() async throws {
        await recorder.start()
        capture.onBuffer?(tone(seconds: 3, gain: 0))
        try await Task.sleep(for: .milliseconds(150))
        #expect(!recorder.isSilent)
        capture.onBuffer?(tone(seconds: 3, gain: 0))
        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.isSilent)
        recorder.pause()
        #expect(!recorder.isSilent)
        recorder.resume()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!recorder.isSilent)
        capture.onBuffer?(tone(seconds: 6, gain: 0))
        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.isSilent)
        capture.onBuffer?(tone(seconds: 1, gain: 0.01))
        try await Task.sleep(for: .milliseconds(150))
        #expect(!recorder.isSilent)
        await recorder.finish()?.value
    }

    @Test func 容量が足りなければ始めない() async throws {
        let recorder = RecorderService(store: store, capture: capture, freeSpace: { 100_000_000 })
        await recorder.start()
        #expect(recorder.state == .idle)
        #expect(try store.all().isEmpty)
    }
}

@MainActor
struct StoreTests {
    let paths: AppPaths
    let store: RecordingStore

    init() throws {
        paths = try makePaths()
        store = try makeStore(paths)
    }

    private func settle() async {
        for task in store.finalizations.values { await task.value }
    }

    private func writeCAF(_ id: UUID, seconds: Double = 1) throws {
        let writer = try CaptureWriter(url: paths.caf(id))
        writer.append(tone(seconds: seconds))
        writer.close()
    }

    private func ready(_ title: String) async throws -> Recording {
        let recording = try store.createForRecording()
        try writeCAF(recording.id)
        await store.beginFinalizing(recording).value
        try store.rename(recording, to: title)
        return recording
    }

    @Test func 録音中に落ちたものを閉じられていないファイルから復元する() async throws {
        let recording = try store.createForRecording()
        let live = paths.root.appending(path: "live.caf")
        let writer = try CaptureWriter(url: live)
        for _ in 0..<50 { writer.append(tone(seconds: 0.1)) }
        // 書き込み中のまま複製する = 強制終了した時点のファイルと同じ内容。
        try FileManager.default.copyItem(at: live, to: paths.caf(recording.id))
        #expect(try store.recover() == 1)
        await settle()
        #expect(recording.state == .ready)
        #expect(recording.wasRecovered)
        // 末尾のごくわずかは、まだファイルに書き出されていないことがある。
        #expect(recording.duration <= 5)
        #expect(recording.duration > 4.9)
        writer.close()
    }

    @Test func 一覧に無い音声ファイルも拾う() async throws {
        let id = UUID()
        try writeCAF(id, seconds: 2)
        try Data().write(to: paths.recordings.appending(path: "\(UUID().uuidString).partial.m4a"))
        try Data().write(to: paths.recordings.appending(path: "memo.caf"))
        #expect(try store.recover() == 1)
        await settle()
        let rows = try store.all()
        #expect(rows.map(\.id) == [id])
        #expect(rows.first?.state == .ready)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.recordings.path(percentEncoded: false)).sorted()
            == ["\(id.uuidString).m4a", "memo.caf"])
    }

    @Test func 何度起動しても復元は重複しない() async throws {
        try writeCAF(UUID())
        #expect(try store.recover() == 1)
        await settle()
        #expect(try store.recover() == 0)
        await settle()
        #expect(try store.all().count == 1)
    }

    @Test func 変換済みで残ったCAFは消す() async throws {
        let recording = try await ready("会議")
        try writeCAF(recording.id)
        #expect(try store.recover() == 0)
        await settle()
        #expect(recording.state == .ready)
        #expect(!exists(paths.caf(recording.id)))
        #expect(exists(paths.m4a(recording.id)))
    }

    @Test func 変換に失敗しても元の音声は消さずやり直せる() async throws {
        let recording = try store.createForRecording()
        try Data("broken".utf8).write(to: paths.caf(recording.id))
        await store.beginFinalizing(recording).value
        #expect(recording.state == .failed)
        #expect(exists(paths.caf(recording.id)))
        try FileManager.default.removeItem(at: paths.caf(recording.id))
        try writeCAF(recording.id)
        await store.beginFinalizing(recording).value
        #expect(recording.state == .ready)
        #expect(recording.failureMessage == nil)
    }

    @Test func 音声ファイルが消えていれば失敗として示す() async throws {
        let recording = try store.createForRecording()
        _ = try store.recover()
        await settle()
        #expect(recording.state == .failed)
    }

    @Test func 削除は最近削除した項目に移り元に戻せる() async throws {
        let recording = try await ready("会議")
        try store.moveToTrash(recording)
        #expect(recording.trashedAt != nil)
        #expect(exists(paths.m4a(recording.id)))
        try store.restore(recording)
        #expect(recording.trashedAt == nil)
    }

    @Test func ゴミ箱に入れていないものは完全削除できない() async throws {
        let recording = try await ready("会議")
        try store.deletePermanently(recording)
        #expect(exists(paths.m4a(recording.id)))
        #expect(try store.all().count == 1)
    }

    @Test func 三十日を過ぎたものだけ完全に消える() async throws {
        let old = try await ready("古い")
        let recent = try await ready("最近")
        let kept = try await ready("残す")
        let oldFile = paths.m4a(old.id)
        try store.moveToTrash(old, now: .now.addingTimeInterval(-31 * 24 * 3600))
        try store.moveToTrash(recent, now: .now.addingTimeInterval(-29 * 24 * 3600))
        try store.purgeExpiredTrash()
        #expect(!exists(oldFile))
        #expect(Set(try store.all().map(\.id)) == [recent.id, kept.id])
    }

    @Test func 処理中のものは削除できない() throws {
        let recording = try store.createForRecording()
        try store.moveToTrash(recording)
        #expect(recording.trashedAt == nil)
    }

    @Test func 名前は重ならず空にはならない() async throws {
        let first = try store.createForRecording()
        let second = try store.createForRecording()
        #expect(first.title == "新規録音")
        #expect(second.title == "新規録音 2")
        try store.rename(first, to: "   ")
        #expect(first.title == "新規録音")
        try store.rename(first, to: " 定例 ")
        #expect(first.title == "定例")
    }

    @Test func 開き直しても内容が残っている() async throws {
        let recording = try await ready("会議")
        let reopened = try makeStore(paths)
        let row = try #require(try reopened.all().first)
        #expect(row.id == recording.id)
        #expect(row.title == "会議")
        #expect(row.state == .ready)
        #expect(!row.waveform.isEmpty)
    }

    @Test func 二重起動を防ぐ() throws {
        var first = InstanceLock(url: paths.lockFile)
        #expect(first != nil)
        #expect(InstanceLock(url: paths.lockFile) == nil)
        first = nil
        #expect(InstanceLock(url: paths.lockFile) != nil)
    }
}

@MainActor
struct LegacyMigrationTests {
    /// 旧名の保存場所を作る。データベースは今の名前で作ってから旧名に付け替える。
    private func makeLegacy() throws -> (URL, UUID) {
        let made = try makePaths()
        let id: UUID
        do {
            let store = try makeStore(made)
            let recording = try store.createForRecording()
            try store.rename(recording, to: "引き継ぐ録音")
            id = recording.id
        }
        FileManager.default.createFile(atPath: made.m4a(id).path(percentEncoded: false), contents: Data([1, 2, 3]))
        let manager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let from = made.root.appending(path: "MicReps.store\(suffix)")
            if manager.fileExists(atPath: from.path(percentEncoded: false)) {
                try manager.moveItem(at: from, to: made.root.appending(path: "VoiceRec.store\(suffix)"))
            }
        }
        let support = made.root.appending(path: ".MicReps_SUPPORT")
        if manager.fileExists(atPath: support.path(percentEncoded: false)) {
            try manager.moveItem(at: support, to: made.root.appending(path: ".VoiceRec_SUPPORT"))
        } else {
            try manager.createDirectory(at: made.root.appending(path: ".VoiceRec_SUPPORT"), withIntermediateDirectories: true)
        }
        return (made.root, id)
    }

    @Test func 旧名の録音を引き継ぐ() throws {
        let (legacy, id) = try makeLegacy()
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appending(path: "MRNew-\(UUID().uuidString)"))
        #expect(try LegacyMigration.moveData(from: legacy, to: paths))
        #expect(!exists(legacy))
        #expect(exists(paths.m4a(id)))
        #expect(exists(paths.root.appending(path: ".MicReps_SUPPORT")))
        let store = try makeStore(paths)
        #expect(try store.all().map(\.title) == ["引き継ぐ録音"])
        // 2回目は何もしない。
        #expect(try LegacyMigration.moveData(from: legacy, to: paths) == false)
    }

    @Test func 旧いアプリが起動中なら移さない() throws {
        let (legacy, _) = try makeLegacy()
        let lock = InstanceLock(url: legacy.appending(path: "lock"))
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appending(path: "MRNew-\(UUID().uuidString)"))
        #expect(throws: LegacyMigration.Failure.self) { try LegacyMigration.moveData(from: legacy, to: paths) }
        #expect(exists(legacy))
        withExtendedLifetime(lock) {}
    }

    @Test func 新しい場所に録音があれば上書きしない() throws {
        let (legacy, _) = try makeLegacy()
        let (other, _) = try makeLegacy()
        let paths = AppPaths(root: other)
        #expect(throws: LegacyMigration.Failure.self) { try LegacyMigration.moveData(from: legacy, to: paths) }
        #expect(exists(legacy))
    }

    @Test func 設定のうち無いものだけを写す() throws {
        let old = "mr.test.old.\(UUID().uuidString)"
        let new = "mr.test.new.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: new))
        defaults.set("en-US", forKey: "kept")
        defaults.setPersistentDomain(["sidePane": "speaking", "kept": "ja-JP", "NSWindow Frame main": "x"], forName: old)
        LegacyMigration.copySettings(from: old, to: defaults)
        #expect(defaults.string(forKey: "sidePane") == "speaking")
        #expect(defaults.string(forKey: "kept") == "en-US")
        #expect(defaults.object(forKey: "NSWindow Frame main") == nil)
        defaults.removePersistentDomain(forName: old)
        defaults.removePersistentDomain(forName: new)
    }
}
