@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// 音声や動画のファイルを、録音と同じ 48kHz モノラルの CAF に直す。元のファイルには触れない。
enum AudioImporter {
    enum Failure: LocalizedError, Equatable {
        case noAudio, protected, noSpace

        var errorDescription: String? {
            switch self {
            case .noAudio: "音声が入っていないか、対応していない形式です。"
            case .protected: "保護されたファイルのため、取り込めません。"
            case .noSpace: "空き容量が足りません。"
            }
        }
    }

    /// 取り込み途中のファイル名の末尾。途中で落ちたものを、起動時に「録音」として復元しないため区別する。
    static let partialSuffix = ".import.caf"

    @concurrent
    static func decode(
        _ source: URL, to target: URL, freeSpace: Int64?, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: target)
        do {
            let writer = try CaptureWriter(url: target)
            defer { writer.close() }
            // 動画は音声トラックが複数あることがあり、音声ファイルとして開くと1本目しか読めない。
            let isMovie = UTType(filenameExtension: source.pathExtension)?.conforms(to: .movie) ?? false
            if !isMovie, let file = try? AVAudioFile(forReading: source), file.length > 0 {
                try check(freeSpace, seconds: Double(file.length) / file.processingFormat.sampleRate)
                try read(file, into: writer, onProgress: onProgress)
            } else {
                try await readAsset(source, into: writer, freeSpace: freeSpace, onProgress: onProgress)
            }
            let result = writer.close()
            if let error = result.error { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: error]) }
            guard result.frames > 0 else { throw Failure.noAudio }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /// 変換中は、展開した音声と圧縮後の両方が一時的に必要になる。
    private static func check(_ freeSpace: Int64?, seconds: Double) throws {
        guard let freeSpace, seconds.isFinite else { return }
        let needed = Int64(seconds * (96_000 + 10_000)) + DiskSpace.critical
        if freeSpace < needed { throw Failure.noSpace }
    }

    private static func read(
        _ file: AVAudioFile, into writer: CaptureWriter, onProgress: (Double) -> Void
    ) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else {
            throw Failure.noAudio
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            writer.append(buffer)
            if writer.snapshot.error != nil { return }
            onProgress(Double(file.framePosition) / Double(file.length))
        }
    }

    /// 動画と、音声ファイルとして直接開けないもの。音声トラックはすべて混ぜる。
    private static func readAsset(
        _ source: URL, into writer: CaptureWriter, freeSpace: Int64?, onProgress: (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        do {
            if try await asset.load(.hasProtectedContent) { throw Failure.protected }
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.noAudio
        }
        guard !tracks.isEmpty else { throw Failure.noAudio }
        let duration = try await asset.load(.duration).seconds
        try check(freeSpace, seconds: duration)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: CaptureWriter.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { throw Failure.noAudio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure.noAudio }
        let format = AVAudioFormat(standardFormatWithSampleRate: CaptureWriter.sampleRate, channels: 1)!
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList
            )
            guard status == noErr else { throw Failure.noAudio }
            writer.append(buffer)
            if writer.snapshot.error != nil { return }
            if duration > 0 { onProgress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)) }
        }
        if reader.status == .failed { throw reader.error ?? Failure.noAudio }
    }
}
