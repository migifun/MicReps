import Charts
import SwiftData
import SwiftUI

/// 振り返り。録音ごとの話し方の数値を並べ、自分のふだんの値と比べる。
struct TrendsView: View {
    let model: AppModel
    @Query(sort: \Recording.createdAt) private var recordings: [Recording]
    @State private var history: [SpeakingMetrics] = []
    @Environment(\.openWindow) private var openWindow

    /// 分析が変わったときだけ数値を作り直す。
    private var cacheKey: [String] {
        recordings.filter { $0.trashedAt == nil }
            .map { "\($0.id)-\($0.analyzedAt?.timeIntervalSince1970 ?? 0)-\($0.title)" }
    }

    var body: some View {
        Group {
            if history.isEmpty {
                ContentUnavailableView(
                    "まだ振り返る録音がありません", systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("30秒以上話した録音の分析が終わると、ここに並びます。")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                            ForEach(SpeakingMetrics.Metric.allCases) { metric in
                                MetricCard(metric: metric, history: history)
                            }
                            HabitCard(history: history)
                        }
                        table
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .navigationTitle("振り返り")
        .onChange(of: cacheKey, initial: true) {
            history = recordings.filter { $0.trashedAt == nil }.compactMap(SpeakingMetrics.init)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(history.count)本の録音").font(.title2.weight(.semibold))
            Text(history.count >= 2
                 ? "いちばん新しい録音を、それより前の録音の中央値(ふだんの値)と比べています。点線がふだんの値、横軸は録音の順(1がいちばん古い)です。"
                 : "録音が2本以上になると、ふだんの値と比べられます。")
                .foregroundStyle(.secondary)
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("録音ごとの値").font(.headline)
            Text("行を押すと、その録音を開きます。").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("録音").gridColumnAlignment(.leading)
                    ForEach(SpeakingMetrics.Metric.allCases) { metric in
                        Text(metric.title).help(metric.help)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider()
                ForEach(history.reversed()) { metrics in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(metrics.title).lineLimit(1)
                            Text(metrics.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .gridColumnAlignment(.leading)
                        ForEach(SpeakingMetrics.Metric.allCases) { metric in
                            Text(metrics.values[metric].map(Self.format) ?? "—").monospacedDigit()
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selection = metrics.id
                        openWindow(id: "main")
                    }
                }
            }
            .font(.callout)
        }
    }

    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}

private struct MetricCard: View {
    let metric: SpeakingMetrics.Metric
    let history: [SpeakingMetrics]

    private var points: [(index: Int, value: Double, title: String)] {
        history.enumerated().compactMap { index, metrics in
            metrics.values[metric].map { (index + 1, $0, metrics.title) }
        }
    }

    var body: some View {
        let latest = history.last?.values[metric]
        let baseline = SpeakingMetrics.baseline(metric, in: history)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.title).font(.headline)
                Spacer()
                if let latest {
                    Text(TrendsView.format(latest)).font(.title3.monospacedDigit().weight(.semibold))
                    Text(metric.unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let latest, let baseline {
                comparison(latest: latest, baseline: baseline)
            }
            Chart {
                ForEach(points, id: \.index) { point in
                    LineMark(x: .value("録音", point.index), y: .value(metric.title, point.value))
                        .foregroundStyle(Color.accentColor)
                    PointMark(x: .value("録音", point.index), y: .value(metric.title, point.value))
                        .foregroundStyle(point.index == history.count ? Color.accentColor : .secondary)
                }
                if let baseline {
                    RuleMark(y: .value("ふだん", baseline))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                }
            }
            .chartXScale(domain: 0.5...Double(max(history.count, 1)) + 0.5)
            .chartXAxis {
                AxisMarks(values: Array(1...max(history.count, 1))) { _ in AxisTick(); AxisValueLabel() }
            }
            .frame(height: 110)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .help(metric.help)
    }

    @ViewBuilder
    private func comparison(latest: Double, baseline: Double) -> some View {
        let change = SpeakingMetrics.change(metric, latest: latest, baseline: baseline)
        let difference = latest - baseline
        let sign = difference >= 0 ? "+" : "−"
        HStack(spacing: 4) {
            switch change {
            case .better: Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(.green)
            case .worse: Image(systemName: "arrow.down.right.circle.fill").foregroundStyle(.orange)
            case .same: Image(systemName: "equal.circle").foregroundStyle(.secondary)
            case .neutral: Image(systemName: "arrow.left.arrow.right.circle").foregroundStyle(.secondary)
            }
            Text("ふだん \(TrendsView.format(baseline)) から \(sign)\(TrendsView.format(abs(difference)))")
            switch change {
            case .better: Text("良くなった").foregroundStyle(.green)
            case .worse: Text("ふだんより悪い").foregroundStyle(.orange)
            case .same: Text("ふだん通り").foregroundStyle(.secondary)
            case .neutral: EmptyView()
            }
        }
        .font(.caption)
    }
}

private struct HabitCard: View {
    let history: [SpeakingMetrics]

    var body: some View {
        let words = SpeakingMetrics.topHabits(history)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("口癖").font(.headline)
                Spacer()
                Text("回/分").font(.caption).foregroundStyle(.secondary)
            }
            if words.isEmpty {
                Text("目立つ口癖はありません。").foregroundStyle(.secondary).frame(height: 130)
            } else {
                Chart {
                    ForEach(words, id: \.self) { word in
                        ForEach(Array(history.enumerated()), id: \.offset) { index, metrics in
                            LineMark(x: .value("録音", index + 1), y: .value("回/分", metrics.habits[word] ?? 0))
                                .foregroundStyle(by: .value("口癖", word))
                            PointMark(x: .value("録音", index + 1), y: .value("回/分", metrics.habits[word] ?? 0))
                                .foregroundStyle(by: .value("口癖", word))
                        }
                    }
                }
                .chartXScale(domain: 0.5...Double(max(history.count, 1)) + 0.5)
                .chartXAxis {
                    AxisMarks(values: Array(1...max(history.count, 1))) { _ in AxisTick(); AxisValueLabel() }
                }
                .frame(height: 130)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .help("よく出る口癖の、話していた時間1分あたりの回数。")
    }
}
