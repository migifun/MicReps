import AVFAudio
import Foundation
import Testing
@testable import MicReps

struct CaptureWriterTests {
    @Test(arguments: [(48_000.0, 1), (44_100.0, 1), (44_100.0, 2), (16_000.0, 1), (48_000.0, 4)])
    func どの入力形式でも長さと音が保たれる(rate: Double, channels: Int) throws {
        let paths = try makePaths()
        let url = paths.caf(UUID())
        let writer = try CaptureWriter(url: url)
        for _ in 0..<20 { writer.append(tone(rate: rate, channels: AVAudioChannelCount(channels), seconds: 0.1)) }
        let result = writer.close()
        #expect(result.error == nil)
        #expect(abs(result.duration - 2) < 0.05)
        #expect((result.levels.max() ?? 0) > 0.25)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == result.frames)
        #expect(file.fileFormat.channelCount == 1)
    }

    @Test func 途中で入力形式が変わっても続けて書ける() throws {
        let writer = try CaptureWriter(url: try makePaths().caf(UUID()))
        writer.append(tone(rate: 48_000, seconds: 1))
        writer.append(tone(rate: 16_000, seconds: 1))
        writer.append(tone(rate: 44_100, channels: 2, seconds: 1))
        let result = writer.close()
        #expect(result.error == nil)
        #expect(abs(result.duration - 3) < 0.1)
    }

    @Test func 閉じた後に届いた音は無視する() throws {
        let writer = try CaptureWriter(url: try makePaths().caf(UUID()))
        writer.append(tone(seconds: 1))
        writer.close()
        writer.append(tone(seconds: 1))
        #expect(writer.snapshot.duration == 1)
    }
}

struct AudioFinalizerTests {
    @Test func m4aに変換され元のCAFは残る() async throws {
        let paths = try makePaths()
        let id = UUID()
        let writer = try CaptureWriter(url: paths.caf(id))
        writer.append(tone(seconds: 3))
        writer.close()
        let output = try await AudioFinalizer.finalize(caf: paths.caf(id), m4a: paths.m4a(id))
        #expect(abs(output.duration - 3) < 0.01)
        #expect(output.waveform.count <= AudioFinalizer.waveformBuckets)
        #expect(output.waveform.count > 500)
        #expect(exists(paths.caf(id)))
        let file = try AVAudioFile(forReading: paths.m4a(id))
        #expect(abs(Double(file.length) / 48_000 - 3) < 0.25)
    }

    @Test func ごく短い録音も変換できる() async throws {
        let paths = try makePaths()
        let id = UUID()
        let writer = try CaptureWriter(url: paths.caf(id))
        writer.append(tone(seconds: 0.1))
        writer.close()
        let output = try await AudioFinalizer.finalize(caf: paths.caf(id), m4a: paths.m4a(id))
        #expect(abs(output.duration - 0.1) < 0.01)
    }

    @Test func 壊れたファイルと無いファイルはエラーになり途中のファイルを残さない() async throws {
        let paths = try makePaths()
        let id = UUID()
        await #expect(throws: AudioFinalizer.Failure.missing) {
            try await AudioFinalizer.finalize(caf: paths.caf(id), m4a: paths.m4a(id))
        }
        try Data("broken".utf8).write(to: paths.caf(id))
        await #expect(throws: (any Error).self) {
            try await AudioFinalizer.finalize(caf: paths.caf(id), m4a: paths.m4a(id))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.recordings.path(percentEncoded: false))
        #expect(names == ["\(id.uuidString).caf"])
    }
}

@MainActor
struct PlayerTests {
    private func loaded(seconds: Double) throws -> PlayerService {
        let url = try makePaths().caf(UUID())
        let writer = try CaptureWriter(url: url)
        // 無音。テスト中に音を出さない。
        writer.append(tone(seconds: seconds, gain: 0))
        writer.close()
        let player = PlayerService()
        player.load(id: UUID(), url: url)
        #expect(player.errorMessage == nil)
        return player
    }

    @Test func 十五秒移動は端で止まる() throws {
        let player = try loaded(seconds: 40)
        player.skip(-15)
        #expect(player.position == 0)
        player.skip(15)
        player.skip(15)
        #expect(player.position == 30)
        player.skip(15)
        #expect(player.position == player.duration)
        player.skip(15)
        #expect(player.position == player.duration)
        player.skip(-15)
        #expect(abs(player.position - 25) < 0.01)
    }

    @Test func 十五秒より短い録音でも壊れない() throws {
        let player = try loaded(seconds: 2)
        player.skip(15)
        #expect(player.position == player.duration)
        player.skip(-15)
        #expect(player.position == 0)
    }

    @Test func 末尾から再生すると先頭に戻り最後で止まる() async throws {
        let player = try loaded(seconds: 0.6)
        player.skip(15)
        player.play()
        #expect(player.isPlaying)
        #expect(player.position < 0.1)
        for _ in 0..<60 where player.isPlaying { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!player.isPlaying)
        #expect(player.position == player.duration)
    }

    @Test func 再生中に末尾を超えて進めると止まる() throws {
        let player = try loaded(seconds: 10)
        player.play()
        player.skip(15)
        #expect(!player.isPlaying)
        #expect(player.position == player.duration)
    }

    @Test func 位置を指定すると停止中なら再生が始まる() throws {
        let player = try loaded(seconds: 40)
        player.play(from: 20)
        #expect(player.isPlaying)
        #expect(abs(player.currentPosition - 20) < 0.5)
        player.play(from: 5)
        #expect(player.isPlaying)
        #expect(abs(player.currentPosition - 5) < 0.5)
        player.pause()
        player.play(from: 40)
        #expect(!player.isPlaying)
        #expect(player.position == player.duration)
        player.play(from: 10)
        #expect(player.isPlaying)
        player.pause()
    }

    @Test func おかしな位置は丸める() {
        #expect(PlayerService.clamp(.nan, duration: 10) == 0)
        #expect(PlayerService.clamp(.infinity, duration: 10) == 0)
        #expect(PlayerService.clamp(-3, duration: 10) == 0)
        #expect(PlayerService.clamp(12, duration: 10) == 10)
    }

    @Test func 開けないファイルは理由を示す() throws {
        let player = PlayerService()
        player.load(id: UUID(), url: try makePaths().caf(UUID()))
        #expect(!player.isLoaded)
        #expect(player.errorMessage != nil)
        player.play()
        player.skip(15)
        #expect(!player.isPlaying)
    }
}

struct TimeTextTests {
    @Test func 表示() {
        #expect(TimeText.short(0) == "0:00")
        #expect(TimeText.short(65.9) == "1:05")
        #expect(TimeText.short(3723) == "1:02:03")
        #expect(TimeText.short(-1) == "0:00")
        #expect(TimeText.short(.nan) == "0:00")
        #expect(TimeText.precise(5.37) == "00:05.3")
    }
}
