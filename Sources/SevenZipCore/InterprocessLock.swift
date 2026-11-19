import Darwin
import Foundation

@_silgen_name("flock")
private func sevenzip_flock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Non-blocking process-wide lock used to keep two updater instances (for
/// example the app and a headless `--self-update --apply`) from racing on the
/// same bundle.
final class InterprocessLock: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var unlocked = false

    init?(url: URL = InterprocessLock.defaultURL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard sevenzip_flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return nil
        }
        descriptor = fd
    }

    static var defaultURL: URL {
        EngineUpdateJournal.defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("engine-update.lock")
    }

    func unlock() {
        lock.lock()
        defer { lock.unlock() }
        guard !unlocked else { return }
        unlocked = true
        sevenzip_flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    deinit {
        unlock()
    }
}
