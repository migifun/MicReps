import Foundation
import Observation

/// 取り込みを1件ずつ順に行う。
@MainActor
@Observable
final class ImportQueue {
    private(set) var currentName: String?
    private(set) var progress: Double = 0
    private(set) var waiting: [URL] = []

    @ObservationIgnored var onNotice: (String) -> Void = { _ in }
    @ObservationIgnored var onImported: (Recording) -> Void = { _ in }

    private let store: RecordingStore
    private let freeSpace: () -> Int64?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var currentID: UUID?

    init(store: RecordingStore, freeSpace: @escaping () -> Int64?) {
        self.store = store
        self.freeSpace = freeSpace
    }

    func add(_ urls: [URL]) {
        waiting += urls.filter(\.isFileURL)
        guard worker == nil, !waiting.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    func waitUntilIdle() async { await worker?.value }

    private func drain() async {
        var failures: [String] = []
        while !waiting.isEmpty {
            let url = waiting.removeFirst()
            currentName = url.deletingPathExtension().lastPathComponent
            progress = 0
            do {
                try await importOne(url)
            } catch {
                failures.append("「\(url.lastPathComponent)」: \(error.localizedDescription)")
            }
            currentName = nil
            currentID = nil
        }
        worker = nil
        // まとめて1回だけ知らせる。
        if !failures.isEmpty { onNotice("取り込めなかったファイルがあります。\n" + failures.joined(separator: "\n")) }
    }

    private func importOne(_ url: URL) async throws {
        let id = UUID()
        currentID = id
        let partial = store.paths.recordings.appending(path: id.uuidString + AudioImporter.partialSuffix)
        try await AudioImporter.decode(url, to: partial, freeSpace: freeSpace()) { [weak self] value in
            Task { @MainActor in
                if self?.currentID == id { self?.progress = value }
            }
        }
        do {
            let recording = try store.createImported(
                id: id, title: url.deletingPathExtension().lastPathComponent, createdAt: Self.creationDate(url), from: partial
            )
            store.beginFinalizing(recording)
            onImported(recording)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// 録音された日時に近い、元のファイルの作成日を使う。未来の日付は今にする。
    private static func creationDate(_ url: URL) -> Date {
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
        return min(created, .now)
    }
}
