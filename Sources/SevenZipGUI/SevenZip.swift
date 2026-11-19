import Foundation

// MARK: - Formats

enum ArchiveFormat: String, CaseIterable, Identifiable {
    case sevenZip = "7z"
    case zip = "zip"
    case tar = "tar"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sevenZip: return "7z"
        case .zip: return "ZIP"
        case .tar: return "TAR"
        }
    }

    var fileExtension: String { rawValue }

    /// 7zz defaults to 7z, so no `-t` switch is needed for it.
    var typeSwitch: String? {
        switch self {
        case .sevenZip: return nil
        case .zip: return "-tzip"
        case .tar: return "-ttar"
        }
    }

    var supportsEncryption: Bool { self != .tar }

    static let archiveExtensions: Set<String> = [
        "7z", "zip", "rar", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz",
        "lzma", "cab", "iso", "dmg", "cpio", "arj", "lzh", "z", "wim", "apfs",
        "msi", "deb", "rpm"
    ]

    static func looksLikeArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Errors

enum SevenZipError: LocalizedError {
    case binaryMissing
    case cancelled
    case failed(code: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return """
            The 7zz engine could not be found. Rebuild the app with Scripts/build-app.sh so it is \
            bundled inside the app, or install it with `brew install sevenzip`.
            """
        case .cancelled:
            return "The operation was cancelled."
        case .failed(let code, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(trimmed.suffix(600))
            return "7zz exited with code \(code)." + (tail.isEmpty ? "" : "\n\n\(tail)")
        }
    }
}

// MARK: - Locating the engine

enum SevenZipLocator {
    static func locate() -> URL? {
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment["SEVENZIP_BIN"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("7zz"))
        }

        // Development fallbacks: walk up from the executable looking for Vendor/7zz,
        // so `swift run` works without a bundled app.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(directory.appendingPathComponent("Vendor/7zz"))
            directory.deleteLastPathComponent()
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/7zz"),
            URL(fileURLWithPath: "/usr/local/bin/7zz"),
            URL(fileURLWithPath: "/usr/bin/7zz")
        ])

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

// MARK: - Command construction

/// Maps UI choices onto 7zz arguments. Kept separate so it can be smoke-tested
/// without driving the interface.
enum SevenZipCommand {
    static func compress(
        sources: [URL],
        output: URL,
        format: ArchiveFormat,
        level: Int,
        password: String,
        encryptFileNames: Bool
    ) -> [String] {
        var arguments = ["a", output.path, "-bsp1", "-y", "-mx=\(level)"]
        if let type = format.typeSwitch {
            arguments.append(type)
        }
        if !password.isEmpty, format.supportsEncryption {
            arguments.append("-p\(password)")
            if format == .sevenZip, encryptFileNames {
                arguments.append("-mhe=on")
            }
            if format == .zip {
                arguments.append("-mem=AES256")
            }
        }
        arguments.append(contentsOf: sources.map(\.path))
        return arguments
    }

    static func extract(archive: URL, destination: URL, password: String) -> [String] {
        var arguments = ["x", archive.path, "-o\(destination.path)", "-bsp1", "-y"]
        if !password.isEmpty {
            arguments.append("-p\(password)")
        }
        return arguments
    }
}

// MARK: - Runner

struct SevenZipResult: Sendable {
    let exitCode: Int32
    let output: String

    /// 7zz uses 1 for "completed with warnings", e.g. a file was skipped.
    var hadWarnings: Bool { exitCode != 0 }
}

/// Runs the bundled `7zz` executable and reports parseable progress.
final class SevenZipRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        let running = lock.withLock { () -> Process? in
            cancelled = true
            return process
        }
        running?.terminate()
    }

    /// Runs 7zz and returns its combined output when it succeeds.
    /// Progress is a percentage in `0...100`; 7zz only reports progress with `-bsp1`.
    func run(
        arguments: [String],
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> SevenZipResult {
        guard let binary = SevenZipLocator.locate() else {
            throw SevenZipError.binaryMissing
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        lock.withLock {
            self.process = process
        }

        if isCancelled {
            lock.withLock { self.process = nil }
            throw SevenZipError.cancelled
        }

        // `waitUntilExit()` can miss the termination notification when 7zz exits
        // very quickly (reproducible in release builds), so wait on an explicit
        // handler instead.
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminated.signal()
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            lock.withLock { self.process = nil }
            throw error
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) { [weak self] in
                var collected = Data()
                var tail = ""
                var lastPercent = -1.0
                let handle = pipe.fileHandleForReading

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    collected.append(chunk)
                    if collected.count > 2_000_000 {
                        collected.removeFirst(collected.count - 1_000_000)
                    }
                    tail += String(decoding: chunk, as: UTF8.self)
                    if tail.count > 8_192 {
                        tail = String(tail.suffix(4_096))
                    }
                    if let percent = Self.latestPercent(in: tail), percent != lastPercent {
                        lastPercent = percent
                        onProgress(percent)
                    }
                }

                terminated.wait()
                let output = Self.cleanOutput(String(decoding: collected, as: UTF8.self))
                let cancelled = self?.isCancelled ?? false
                if let self {
                    self.lock.withLock { self.process = nil }
                }

                if cancelled {
                    continuation.resume(throwing: SevenZipError.cancelled)
                } else if process.terminationStatus == 0 || process.terminationStatus == 1 {
                    continuation.resume(
                        returning: SevenZipResult(
                            exitCode: process.terminationStatus,
                            output: output
                        )
                    )
                } else {
                    continuation.resume(
                        throwing: SevenZipError.failed(
                            code: process.terminationStatus,
                            output: output
                        )
                    )
                }
            }
        }
    }

    // MARK: Output parsing

    private static let percentRegex = try! NSRegularExpression(pattern: #"([0-9]{1,3})%"#)

    static func latestPercent(in text: String) -> Double? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = percentRegex.matches(in: text, range: range).last,
            let valueRange = Range(match.range(at: 1), in: text),
            let value = Double(text[valueRange])
        else { return nil }
        return min(max(value, 0), 100)
    }

    /// 7zz draws progress with `\r` and backspaces; turn that into readable log text.
    static func cleanOutput(_ raw: String) -> String {
        var output = ""
        for character in raw {
            switch character {
            case "\u{8}":
                if !output.isEmpty { output.removeLast() }
            case "\r":
                if let newline = output.lastIndex(of: "\n") {
                    output = String(output[...newline])
                } else {
                    output = ""
                }
            default:
                output.append(character)
            }
        }
        return output
    }
}
