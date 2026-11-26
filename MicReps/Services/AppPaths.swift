import Foundation

struct AppPaths: Sendable {
    let root: URL

    var recordings: URL { root.appending(path: "recordings", directoryHint: .isDirectory) }
    var database: URL { root.appending(path: "MicReps.store") }
    var lockFile: URL { root.appending(path: "lock") }

    func caf(_ id: UUID) -> URL { recordings.appending(path: "\(id.uuidString).caf") }
    func m4a(_ id: UUID) -> URL { recordings.appending(path: "\(id.uuidString).m4a") }
    func audio(_ recording: Recording) -> URL { recordings.appending(path: recording.audioFileName) }

    func createDirectories() throws {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    }

    static var standard: AppPaths {
        #if DEBUG
        if let custom = ProcessInfo.processInfo.environment["MICREPS_HOME"] {
            return AppPaths(root: URL(filePath: custom, directoryHint: .isDirectory))
        }
        // 開発版は、実際の録音とは別の場所を使う。
        let name = "MicReps-Debug"
        #else
        let name = "MicReps"
        #endif
        return AppPaths(root: URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory))
    }

    /// 旧名(VoiceRec)のときの保存場所。
    static var legacyStandard: URL {
        #if DEBUG
        let name = "VoiceRec-Debug"
        #else
        let name = "VoiceRec"
        #endif
        return URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    }
}

/// 旧名 VoiceRec で保存した録音と設定を、MicReps へ引き継ぐ。
enum LegacyMigration {
    enum Failure: LocalizedError {
        case oldAppRunning, bothExist

        var errorDescription: String? {
            switch self {
            case .oldAppRunning: "旧名のVoiceRecが起動しています。VoiceRecを終了してから、もう一度開いてください。"
            case .bothExist: "VoiceRecとMicRepsの両方の保存場所に録音があるため、引き継げませんでした。"
            }
        }
    }

    private static let oldStore = "VoiceRec"
    private static let newStore = "MicReps"

    /// 新しい場所にまだ何も無いときだけ、旧い場所をまるごと移す。移したら true。
    @discardableResult
    static func moveData(from legacy: URL, to paths: AppPaths) throws -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacy.path(percentEncoded: false)) else { return false }
        if manager.fileExists(atPath: paths.root.path(percentEncoded: false)) {
            // 中身の無いフォルダだけなら、作りかけとして消してよい。
            let recordings = (try? manager.contentsOfDirectory(atPath: paths.recordings.path(percentEncoded: false))) ?? []
            guard !manager.fileExists(atPath: paths.database.path(percentEncoded: false)), recordings.isEmpty else {
                let old = (try? manager.contentsOfDirectory(atPath: legacy.appending(path: "recordings").path(percentEncoded: false))) ?? []
                if old.isEmpty { return false }
                throw Failure.bothExist
            }
            try manager.removeItem(at: paths.root)
        }
        // 旧いアプリが録音中かもしれないので、旧い場所の鍵が取れるときだけ移す。
        guard let lock = InstanceLock(url: legacy.appending(path: "lock")) else { throw Failure.oldAppRunning }
        try withExtendedLifetime(lock) {
            try manager.createDirectory(at: paths.root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: legacy, to: paths.root)
        }
        // データベースの名前も新しくする。添付データのフォルダは名前で結び付いているので一緒に変える。
        for (old, new) in [
            ("\(oldStore).store", "\(newStore).store"), ("\(oldStore).store-shm", "\(newStore).store-shm"),
            ("\(oldStore).store-wal", "\(newStore).store-wal"), (".\(oldStore)_SUPPORT", ".\(newStore)_SUPPORT"),
        ] {
            let from = paths.root.appending(path: old)
            guard manager.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            try manager.moveItem(at: from, to: paths.root.appending(path: new))
        }
        return true
    }

    /// 旧いアプリの設定のうち、まだ無いものを写す。
    static func copySettings(from domain: String, to defaults: UserDefaults = .standard) {
        guard let old = defaults.persistentDomain(forName: domain) else { return }
        for (key, value) in old where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && !key.hasPrefix("com.apple") {
            if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
    }

    static var legacyDefaultsDomain: String {
        #if DEBUG
        "local.voicerec.VoiceRec.debug"
        #else
        "local.voicerec.VoiceRec"
        #endif
    }
}

/// 二重起動の防止。2つ目が起動すると、1つ目の録音中ファイルを「異常終了」と誤認してしまうため。
/// プロセスが落ちるとOSが自動で解放する。
final class InstanceLock {
    private let descriptor: Int32

    init?(url: URL) {
        let fd = open(url.path(percentEncoded: false), O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

enum DiskSpace {
    static let warning: Int64 = 1_000_000_000
    static let critical: Int64 = 200_000_000

    static func available(at url: URL) -> Int64? {
        // URLは値をキャッシュするため、毎回作り直した URL で読む。
        let fresh = URL(filePath: url.path(percentEncoded: false))
        guard let bytes = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else {
            return nil
        }
        return Int64(bytes)
    }
}
