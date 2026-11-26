import SwiftUI

struct RecorderView: View {
    let model: AppModel

    private var recorder: RecorderService { model.recorder }
    private var isPaused: Bool { recorder.state == .paused }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 6) {
                Text(recorder.current?.title ?? "").font(.title2.weight(.semibold))
                Label(isPaused ? "一時停止中" : "録音中", systemImage: isPaused ? "pause.fill" : "record.circle")
                    .foregroundStyle(isPaused ? Color.secondary : Color.red)
            }
            LiveWaveform(levels: recorder.levels, isPaused: isPaused)
                .frame(height: 120)
                .accessibilityHidden(true)
            if recorder.isSilent {
                Label("音が入っていないようです。マイクを確認してください。", systemImage: "mic.slash")
                    .foregroundStyle(.orange)
            } else if let name = recorder.inputName {
                Label(name, systemImage: "mic").font(.callout).foregroundStyle(.secondary)
            }
            Text(TimeText.precise(recorder.elapsed))
                .font(.system(size: 44, weight: .light).monospacedDigit())
                .accessibilityLabel("経過時間 \(TimeText.short(recorder.elapsed))")
            HStack(spacing: 16) {
                Button { model.togglePause() } label: {
                    Label(isPaused ? "再開" : "一時停止", systemImage: isPaused ? "record.circle" : "pause.fill")
                        .frame(width: 110)
                }
                Button { model.toggleRecording() } label: {
                    Label("完了", systemImage: "stop.fill").frame(width: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.large)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("録音")
    }
}

private struct LiveWaveform: View {
    let levels: [Float]
    let isPaused: Bool

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 4
            let visible = levels.suffix(Int(size.width / step))
            var x = size.width - CGFloat(visible.count) * step
            for level in visible {
                context.fill(WaveformBar.path(level, x: x, width: 2.5, height: size.height),
                             with: .color(isPaused ? .secondary : .red))
                x += step
            }
        }
    }
}

enum WaveformBar {
    static func path(_ level: Float, x: CGFloat, width: CGFloat, height: CGFloat) -> Path {
        // 小さな声も見えるように平方根で持ち上げる。
        let h = max(2, CGFloat(min(1, max(0, level))).squareRoot() * height)
        return Path(roundedRect: CGRect(x: x, y: (height - h) / 2, width: width, height: h), cornerRadius: width / 2)
    }
}
