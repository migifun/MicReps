import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class RecorderService {
    enum State { case idle, recording, paused }

    private(set) var state: State = .idle
    private(set) var elapsed: Double = 0
    private(set) var levels: [Float] = []
    private(set) var current: Recording?
    private(set) var inputName: String?
    /// しばらく音がまったく入っていない。
    private(set) var isSilent = false

    /// 5秒間この大きさに届かなければ無音とみなす。静かな部屋の雑音より十分小さい。
    private static let silenceLevel: Float = 0.0005
    private static let silenceWindow = 100

    var isActive: Bool { state != .idle }

    /// 利用者へのお知らせ。
    @ObservationIgnored var onNotice: (String) -> Void = { _ in }
    @ObservationIgnored var onPermissionDenied: () -> Void = {}
    @ObservationIgnored var onFinished: (Recording) -> Void = { _ in }

    private let store: RecordingStore
    private let capture: AudioCapture
    private let freeSpace: () -> Int64?
    @ObservationIgnored private var writer: CaptureWriter?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var isStarting = false
    /// 古い入力からの遅れた通知を無視するための番号。
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var restarts: [Date] = []
    /// 再開やマイクの切り替え前の音で判断しないための基準。
    @ObservationIgnored private var levelsAtStart = 0
    @ObservationIgnored private var warnedLowSpace = false

    init(store: RecordingStore, capture: AudioCapture, freeSpace: @escaping () -> Int64?) {
        self.store = store
        self.capture = capture
        self.freeSpace = freeSpace
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause(notice: "Macがスリープしたため、録音を一時停止しました。") }
        }
    }

    func start() async {
        guard state == .idle, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        guard await capture.requestPermission() else {
            onPermissionDenied()
            return
        }
        let space = freeSpace()
        if let space, space < DiskSpace.critical {
            onNotice("空き容量が足りないため、録音を始められません。")
            return
        }

        var created: Recording?
        do {
            let recording = try store.createForRecording()
            created = recording
            let writer = try CaptureWriter(url: store.paths.caf(recording.id))
            self.writer = writer
            try startCapture(into: writer)
            current = recording
            elapsed = 0
            levels = []
            restarts = []
            warnedLowSpace = false
            state = .recording
            beginActivity()
            startMonitor()
            checkSpace(space)
        } catch {
            capture.stop()
            writer?.close()
            writer = nil
            if let created { try? store.discard(created) }
            onNotice("録音を始められませんでした。\(error.localizedDescription)")
        }
    }

    func pause(notice: String? = nil) {
        guard state == .recording else { return }
        stopCapture()
        state = .paused
        refresh()
        endActivity()
        if let notice { onNotice(notice) }
    }

    func resume() {
        guard state == .paused, let writer else { return }
        do {
            try startCapture(into: writer)
            restarts = []
            state = .recording
            beginActivity()
            startMonitor()
        } catch {
            capture.stop()
            onNotice("録音を再開できませんでした。\(error.localizedDescription)")
        }
    }

    /// 録音を終え、変換を始める。音が1つも入っていなければ何も残さない。
    @discardableResult
    func finish() -> Task<Void, Never>? {
        guard isActive, let recording = current, let writer else { return nil }
        stopCapture()
        let result = writer.close()
        endActivity()
        self.writer = nil
        current = nil
        state = .idle
        elapsed = 0
        levels = []
        isSilent = false

        guard result.frames > 0 else {
            try? store.discard(recording)
            onNotice("音声が記録されなかったため、保存しませんでした。")
            return nil
        }
        recording.duration = result.duration
        let task = store.beginFinalizing(recording)
        onFinished(recording)
        return task
    }

    // MARK: - 入力

    private func startCapture(into writer: CaptureWriter) throws {
        session += 1
        let session = session
        inputName = capture.inputName
        levelsAtStart = writer.snapshot.measured
        try capture.start(
            onBuffer: { writer.append($0) },
            onInterruption: { [weak self] kind in
                Task { @MainActor in self?.handleInterruption(kind, session: session) }
            }
        )
    }

    private func stopCapture() {
        session += 1
        capture.stop()
        monitor?.cancel()
        monitor = nil
    }

    private func handleInterruption(_ kind: CaptureInterruption, session: Int) {
        guard session == self.session, state == .recording, let writer else { return }
        switch kind {
        case .deviceChanged:
            pause(notice: "マイクが変わったため、録音を一時停止しました。再開すると今のマイクで続けます。")
        case .configurationChanged:
            // 同じマイクの設定変更なら、利用者に見せず続ける。短時間に繰り返すなら止める。
            let now = Date.now
            restarts = restarts.filter { now.timeIntervalSince($0) < 10 } + [now]
            do {
                guard restarts.count <= 3 else { throw CaptureError.noInput }
                capture.stop()
                try startCapture(into: writer)
            } catch {
                pause(notice: "マイクの入力が止まったため、録音を一時停止しました。")
            }
        }
    }

    // MARK: - 監視

    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
                tick += 1
                if tick % 100 == 0 { self.checkSpace(self.freeSpace()) }
            }
        }
    }

    private func refresh() {
        guard let writer else { return }
        let snapshot = writer.snapshot
        elapsed = snapshot.duration
        levels = snapshot.levels
        let recent = levels.suffix(Self.silenceWindow)
        isSilent = state == .recording && snapshot.measured - levelsAtStart >= Self.silenceWindow
            && recent.allSatisfy { $0 < Self.silenceLevel }
        if let error = snapshot.error, state != .idle {
            finish()
            onNotice("録音の書き込みに失敗したため、ここまでを保存しました。\(error)")
        }
    }

    func checkSpace(_ space: Int64?) {
        guard let space, state == .recording else { return }
        if space < DiskSpace.critical {
            finish()
            onNotice("空き容量がなくなりそうなため、録音を終了して保存しました。")
        } else if space < DiskSpace.warning, !warnedLowSpace {
            warnedLowSpace = true
            onNotice("空き容量が1GBを切っています。足りなくなる前に、自動で保存して終了します。")
        }
    }

    private func beginActivity() {
        endActivity()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "録音中"
        )
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
