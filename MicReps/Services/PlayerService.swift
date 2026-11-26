import AVFAudio
import Foundation
import Observation

@MainActor
@Observable
final class PlayerService: NSObject {
    static let skipInterval = 15.0
    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    private(set) var loadedID: UUID?
    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private(set) var isPlaying = false
    private(set) var errorMessage: String?
    var rate: Float = 1 {
        didSet { player?.rate = rate }
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// 一度でも再生・移動したか。開いた直後に先頭の文を強調しないために使う。
    private(set) var hasStarted = false

    var isLoaded: Bool { player != nil }

    func load(id: UUID, url: URL) {
        guard loadedID != id || player?.url != url else { return }
        unload()
        loadedID = id
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.rate = rate
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            duration = player.duration
        } catch {
            errorMessage = "音声を開けませんでした。\(error.localizedDescription)"
        }
    }

    func unload() {
        stopTicker()
        player?.delegate = nil
        player?.stop()
        player = nil
        loadedID = nil
        duration = 0
        position = 0
        isPlaying = false
        hasStarted = false
        errorMessage = nil
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player, !isPlaying else { return }
        if position >= duration - 0.05 { position = 0 }
        player.currentTime = position
        player.rate = rate
        guard player.play() else {
            errorMessage = "再生できませんでした。"
            return
        }
        isPlaying = true
        hasStarted = true
        startTicker()
    }

    func pause() {
        guard let player, isPlaying else { return }
        position = min(player.currentTime, duration)
        player.pause()
        isPlaying = false
        stopTicker()
    }

    func seek(to time: Double) {
        guard let player else { return }
        hasStarted = true
        let target = Self.clamp(time, duration: duration)
        if target >= duration - 0.05 {
            // AVAudioPlayerは末尾ちょうどへ移動すると先頭に戻ることがあるため、止めて末尾に留める。
            reachEnd()
        } else {
            position = target
            player.currentTime = target
        }
    }

    /// その位置へ移動し、止まっていれば再生を始める。
    func play(from time: Double) {
        seek(to: time)
        // 末尾へ移動したときは、先頭から再生し直さずに止めておく。
        if !isPlaying, position < duration { play() }
    }

    func skip(_ seconds: Double) {
        seek(to: currentPosition + seconds)
    }

    /// 表示用の更新を待たない、今の正確な位置。
    var currentPosition: Double {
        guard let player, isPlaying, player.isPlaying else { return position }
        return player.currentTime
    }

    static func clamp(_ time: Double, duration: Double) -> Double {
        guard time.isFinite else { return 0 }
        return min(max(0, time), max(0, duration))
    }

    private func reachEnd() {
        player?.pause()
        isPlaying = false
        position = duration
        stopTicker()
    }

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, self.isPlaying, let player = self.player else { return }
                // 終端で自然に止まった瞬間、currentTimeが0に戻るのを拾わない。
                if player.isPlaying { self.position = min(player.currentTime, self.duration) }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}

extension PlayerService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            // 読み込み直した後や、末尾で再生し直した後に届いた通知は無視する。
            guard let current = self.player, ObjectIdentifier(current) == finished,
                  self.isPlaying, !current.isPlaying else { return }
            self.reachEnd()
        }
    }
}
