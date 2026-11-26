import Foundation

enum TimeText {
    /// 1:05 / 1:02:03
    static func short(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 録音中の表示。00:05.3
    static func precise(_ seconds: Double) -> String {
        let tenths = seconds.isFinite ? max(0, Int(seconds * 10)) : 0
        let total = tenths / 10
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d.%d", h, m, s, tenths % 10)
            : String(format: "%02d:%02d.%d", m, s, tenths % 10)
    }
}
