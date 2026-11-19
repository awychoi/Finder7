import Foundation

/// A small crash journal so a process kill between the engine swap and the
/// final signature cannot leave a half-updated bundle. It lives outside the
/// bundle so writing it does not invalidate the signature.
public struct EngineUpdateJournal: Codable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case prepared
        case backedUp
        case swapped
        case manifestWritten
        case signed
        case completed
    }

    public var bundlePath: String
    public var phase: Phase
    public var previousVersion: String
    public var targetVersion: String
    public var previousManifest: String?
    public var previousProvenance: String?
    public var createdAt: Date

    public init(
        bundlePath: String,
        phase: Phase = .prepared,
        previousVersion: String,
        targetVersion: String,
        previousManifest: String?,
        previousProvenance: String?,
        createdAt: Date = Date()
    ) {
        self.bundlePath = bundlePath
        self.phase = phase
        self.previousVersion = previousVersion
        self.targetVersion = targetVersion
        self.previousManifest = previousManifest
        self.previousProvenance = previousProvenance
        self.createdAt = createdAt
    }

    public static var defaultURL: URL {
        supportDirectory.appendingPathComponent("engine-update-journal.json")
    }

    /// Application Support normally. `SEVENZIP_SUPPORT_DIR` lets the offline
    /// self-update test keep its journal and process lock inside its own
    /// temporary directory; sandboxed test harnesses can make the real
    /// Application Support directory read-only.
    public static var supportDirectory: URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SEVENZIP_SUPPORT_DIR"],
           !override.isEmpty {
            let directory = URL(fileURLWithPath: override, isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        if let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let directory = base.appendingPathComponent("Finder7", isDirectory: true)
            if (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil {
                return directory
            }
        }
        let fallback = fileManager.temporaryDirectory.appendingPathComponent("Finder7", isDirectory: true)
        try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    public func write(to url: URL = EngineUpdateJournal.defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: [.atomic])
    }

    public static func read(from url: URL = EngineUpdateJournal.defaultURL) -> EngineUpdateJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(EngineUpdateJournal.self, from: data)
    }

    public static func remove(at url: URL = EngineUpdateJournal.defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}

public enum EngineUpdateRecovery {
    public enum Outcome: Sendable, Equatable {
        case none
        case completed
        case rolledBack(previousVersion: String)
        case failed(String)
    }

    /// Rolls back an update that was interrupted after the engine swap. Called
    /// at launch and before starting another update. It never checks the
    /// network and never installs anything.
    @discardableResult
    public static func recoverIfNeeded(
        bundle: URL,
        journalURL: URL = EngineUpdateJournal.defaultURL,
        hooks: InstallationHooks = .live
    ) -> Outcome {
        guard let journal = EngineUpdateJournal.read(from: journalURL) else { return .none }
        let bundlePath = bundle.standardizedFileURL.path
        guard journal.bundlePath == bundlePath else { return .none }

        if journal.phase == .completed {
            EngineUpdateJournal.remove(at: journalURL)
            return .completed
        }

        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let engine = resources.appendingPathComponent("7zz")
        let previous = resources.appendingPathComponent("7zz.previous")
        let staged = resources.appendingPathComponent("7zz.new")
        let manifestURL = resources.appendingPathComponent("homelab-app.json")
        let provenanceURL = resources.appendingPathComponent("engine-provenance.txt")
        let fileManager = FileManager.default

        let currentVersion = engineVersion(at: engine)
        let hasPrevious = fileManager.fileExists(atPath: previous.path)
        // The phase is the first signal. The banner catches a process kill in
        // the tiny window after rename but before the journal phase update.
        let engineWasSwapped = journal.phase == .swapped
            || journal.phase == .manifestWritten
            || journal.phase == .signed
            || (currentVersion != nil && currentVersion == journal.targetVersion
                && currentVersion != journal.previousVersion)

        do {
            if engineWasSwapped {
                guard hasPrevious else {
                    return .failed("The new engine was installed but 7zz.previous is missing.")
                }
                try InstallationSupport.replaceContents(of: engine, with: previous)
                if let previousManifest = journal.previousManifest {
                    try Data(previousManifest.utf8).write(to: manifestURL, options: [.atomic])
                } else {
                    try? fileManager.removeItem(at: manifestURL)
                }
                if let previousProvenance = journal.previousProvenance {
                    try Data(previousProvenance.utf8).write(to: provenanceURL, options: [.atomic])
                } else {
                    try? fileManager.removeItem(at: provenanceURL)
                }
                try hooks.signEngine(engine)
            }
            try? fileManager.removeItem(at: staged)
            // Adding 7zz.new (or 7zz.previous) changed the sealed resource
            // directory, so re-sign whatever is now on disk.
            try hooks.signBundle(bundle)
            try hooks.verifySignature(bundle)
            EngineUpdateJournal.remove(at: journalURL)
            return .rolledBack(previousVersion: journal.previousVersion)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func engineVersion(at url: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        guard let result = try? CommandRunner.run(url.path, arguments: []) else { return nil }
        let banner = result.combined
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]+\.[0-9]+"#),
              let match = regex.firstMatch(in: banner, range: NSRange(banner.startIndex..<banner.endIndex, in: banner)),
              let range = Range(match.range, in: banner)
        else { return nil }
        return String(banner[range])
    }
}
