import Foundation

/// 章。文の番号ではなく時刻で持つ。文字起こしをやり直しても位置がずれない。
struct Chapter: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Double
    var title: String
    var isEdited = false

    /// その時刻が含まれる章。最初の章より前なら nil。
    static func index(at time: Double, in chapters: [Chapter]) -> Int? {
        chapters.lastIndex { $0.start <= time + 0.02 }
    }

    /// 前の章へ。章の途中なら、まずその章の頭へ戻る。
    static func previousStart(from time: Double, in chapters: [Chapter]) -> Double? {
        guard let index = index(at: time, in: chapters) else { return nil }
        if time - chapters[index].start > 3 || index == 0 { return chapters[index].start }
        return chapters[index - 1].start
    }

    static func nextStart(from time: Double, in chapters: [Chapter]) -> Double? {
        chapters.first { $0.start > time + 0.02 }?.start
    }
}
