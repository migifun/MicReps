@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import MicReps

@MainActor
struct ImportTests {
    let paths: AppPaths
    let store: RecordingStore
    let imports: ImportQueue
    let folder: URL

    init() throws {
        paths = try makePaths()
        store = try makeStore(paths)
        imports = ImportQueue(store: store, freeSpace: { 50_000_000_000 })
        folder = paths.root.appending(path: "source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func audioFile(_ name: String, rate: Double, channels: AVAudioChannelCount, aac: Bool = false) throws -> URL {
        let url = folder.appending(path: name)
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
        settings[AVFormatIDKey] = aac ? kAudioFormatMPEG4AAC : kAudioFormatLinearPCM
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: tone(rate: rate, channels: channels, seconds: 3))
        file.close()
        return url
    }

    /// 映像と音声を持つ動画。
    private func movie(_ name: String, withAudio: Bool) async throws -> URL {
        let url = folder.appending(path: name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ])
        audio.expectsMediaDataInRealTime = true
        if withAudio { writer.add(audio) }
        /// 書き込みに失敗すると永久に準備完了にならないので、状態も見て待つ。
        func waitUntilReady(_ input: AVAssetWriterInput) async throws {
            while !input.isReadyForMoreMediaData {
                try #require(writer.status == .writing, "\(String(describing: writer.error))")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        // 映像と音声は交互に書く。片方だけ先に書くと、もう片方を待って止まる。
        for i in 0..<30 {
            try await waitUntilReady(video)
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels)
            adaptor.append(pixels!, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
            guard withAudio else { continue }
            try await waitUntilReady(audio)
            let buffer = tone(seconds: 0.1)
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: CMTime(value: Int64(i) * 4800, timescale: 48_000), decodeTimeStamp: .invalid
            )
            CMSampleBufferCreate(
                allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: buffer.format.formatDescription, sampleCount: 4800, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
            )
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                bufferList: buffer.audioBufferList
            )
            audio.append(sample!)
        }
        video.markAsFinished()
        if withAudio { audio.markAsFinished() }
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private func run(_ urls: [URL]) async -> [String] {
        var notices: [String] = []
        imports.onNotice = { notices.append($0) }
        imports.add(urls)
        await imports.waitUntilIdle()
        for task in store.finalizations.values { await task.value }
        return notices
    }

    @Test func いろいろな形式を取り込める() async throws {
        let urls = [
            try audioFile("会議.wav", rate: 44_100, channels: 2), try audioFile("メモ.m4a", rate: 48_000, channels: 1, aac: true),
            try audioFile("低音質.wav", rate: 8_000, channels: 1), try audioFile("多ch.caf", rate: 48_000, channels: 4),
        ]
        let notices = await run(urls)
        #expect(notices.isEmpty)
        let rows = try store.all()
        #expect(Set(rows.map(\.title)) == ["会議", "メモ", "低音質", "多ch"])
        for row in rows {
            #expect(row.state == .ready)
            #expect(abs(row.duration - 3) < 0.1, "\(row.title) \(row.duration)")
            #expect((row.waveform.max() ?? 0) > 0.2, "\(row.title)")
        }
        #expect(urls.allSatisfy(exists))
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.recordings.path(percentEncoded: false)).allSatisfy { $0.hasSuffix(".m4a") })
    }

    @Test func 動画から音声を取り込める() async throws {
        let url = try await movie("打ち合わせ.mp4", withAudio: true)
        #expect(await run([url]).isEmpty)
        let row = try #require(try store.all().first)
        #expect(row.state == .ready)
        #expect(abs(row.duration - 3) < 0.2)
        #expect((row.waveform.max() ?? 0) > 0.2)
    }

    @Test func 音声の無い動画や別のファイルは断り残りは続ける() async throws {
        let silent = try await movie("無音.mp4", withAudio: false)
        let text = folder.appending(path: "文書.txt")
        try Data("これは音声ではありません".utf8).write(to: text)
        let missing = folder.appending(path: "無い.m4a")
        let good = try audioFile("良い.wav", rate: 48_000, channels: 1)
        let notices = await run([silent, text, missing, good])
        #expect(notices.count == 1)
        #expect(["無音.mp4", "文書.txt", "無い.m4a"].allSatisfy { notices[0].contains($0) })
        #expect(try store.all().map(\.title) == ["良い"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.recordings.path(percentEncoded: false)).count == 1)
    }

    @Test func 容量が足りなければ何も残さない() async throws {
        let small = ImportQueue(store: store, freeSpace: { 200_100_000 })
        var notice = ""
        small.onNotice = { notice = $0 }
        small.add([try audioFile("長い.wav", rate: 48_000, channels: 1)])
        await small.waitUntilIdle()
        #expect(notice.contains("空き容量"))
        #expect(try store.all().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.recordings.path(percentEncoded: false)).isEmpty)
    }

    @Test func 取り込み途中で落ちたものは復元せず片付ける() throws {
        try Data("途中".utf8).write(to: paths.recordings.appending(path: UUID().uuidString + AudioImporter.partialSuffix))
        #expect(try store.recover() == 0)
        #expect(try store.all().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.recordings.path(percentEncoded: false)).isEmpty)
    }

    @Test func 取り込みのあと文字起こしまで進む() async throws {
        let other = try makePaths()
        let transcriber = FakeTranscriber()
        let model = try AppModel(paths: other, capture: FakeCapture(), transcriber: transcriber, generator: FakeGenerator(), reviewer: FakeReviewer())
        model.imports.add([try audioFile("講演.wav", rate: 48_000, channels: 1)])
        await model.imports.waitUntilIdle()
        for task in model.store.finalizations.values { await task.value }
        await model.queue.waitUntilIdle()
        let row = try #require(try model.store.all().first)
        #expect(model.selection == row.id)
        #expect(row.transcriptState == .done)
    }

    @Test func ゴミ箱を空にしても残りは消えない() async throws {
        _ = await run([try audioFile("a.wav", rate: 48_000, channels: 1), try audioFile("b.wav", rate: 48_000, channels: 1)])
        let a = try #require(try store.all().first { $0.title == "a" })
        try store.moveToTrash(a)
        try store.emptyTrash()
        #expect(try store.all().map(\.title) == ["b"])
    }
}

struct ExportTests {
    private let transcript = Transcript(locale: "ja-JP", sentences: [
        Sentence(start: 0.5, end: 2, text: "一。"), Sentence(start: 2, end: 2.1, text: "二。"),
        Sentence(start: 3661.25, end: 3664, text: "三。"),
    ])
    private let chapters = [Chapter(start: 0, title: "導入"), Chapter(start: 3661.25, title: "結論")]

    private func text(_ kind: ExportKind) -> String? {
        Exporter.text(kind, title: "会議", createdAt: Date(timeIntervalSince1970: 0), duration: 3700,
                      transcript: transcript, chapters: chapters)
    }

    @Test func 字幕は時刻の形式が正しく重ならない() {
        #expect(text(.subtitles) == """
            1
            00:00:00,500 --> 00:00:02,000
            一。

            2
            00:00:02,000 --> 00:00:02,800
            二。

            3
            01:01:01,250 --> 01:01:04,000
            三。

            """)
    }

    @Test func Markdownは章が見出しになる() throws {
        let markdown = try #require(text(.markdown))
        #expect(markdown.hasPrefix("# 会議\n\n"))
        #expect(markdown.contains("/ 1:01:40\n\n## 0:00 導入\n\n一。  \n二。  \n\n## 1:01:01 結論\n\n三。  \n"))
    }

    @Test func テキスト() {
        #expect(text(.text) == "一。\n二。\n三。\n")
        #expect(text(.timestampedText) == "[0:00] 一。\n[0:02] 二。\n[1:01:01] 三。\n")
        #expect(text(.audio) == nil)
    }

    @Test func ファイル名に使えない文字を避ける() {
        #expect(Exporter.fileName(for: "11/26 10:00 会議", extension: "txt") == "11-26 10-00 会議.txt")
        #expect(Exporter.fileName(for: "..秘密", extension: "md") == "秘密.md")
        #expect(Exporter.fileName(for: " / ", extension: "md") == "-.md")
        #expect(Exporter.fileName(for: "", extension: "m4a") == "録音.m4a")
        let long = Exporter.fileName(for: String(repeating: "長", count: 300), extension: "m4a")
        #expect(long.utf8.count <= 255)
    }

    @MainActor
    @Test func 音声と文字をファイルに書き出し既存のファイルは置き換える() async throws {
        let paths = try makePaths()
        let capture = FakeCapture()
        let model = try AppModel(paths: paths, capture: capture, transcriber: FakeTranscriber(), generator: FakeGenerator(), reviewer: FakeReviewer())
        await model.recorder.start()
        capture.onBuffer?(tone(seconds: 2))
        await model.recorder.finish()?.value
        let recording = try #require(try model.store.all().first)
        #expect(!model.canExport(.text, recording))
        #expect(model.canExport(.audio, recording))
        await model.queue.waitUntilIdle()
        #expect(model.canExport(.text, recording))

        let audio = paths.root.appending(path: "出力.m4a")
        try Data("古い内容".utf8).write(to: audio)
        model.write(.audio, recording.id, to: audio)
        #expect(try AVAudioFile(forReading: audio).length > 0)
        #expect(exists(paths.m4a(recording.id)))
        // 保存先に元のファイル自身を選んでも壊さない。
        model.write(.audio, recording.id, to: paths.m4a(recording.id))
        #expect(try AVAudioFile(forReading: paths.m4a(recording.id)).length > 0)

        let text = paths.root.appending(path: "出力.txt")
        model.write(.text, recording.id, to: text)
        #expect(try String(contentsOf: text, encoding: .utf8) == "こんにちは。\n")
        #expect(model.notices.isEmpty)
        model.write(.text, UUID(), to: text)
        model.write(.text, recording.id, to: URL(filePath: "/存在しない/出力.txt"))
        #expect(model.notices.count == 2)
    }
}
