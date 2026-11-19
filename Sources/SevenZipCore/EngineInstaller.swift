import Darwin
import Foundation

public enum InstallStep: String, Sendable, CaseIterable {
    case backup
    case swap
    case manifest
    case signEngine
    case signBundle
    case verifySignature

    public var title: String {
        switch self {
        case .backup: return "backing up the installed engine"
        case .swap: return "swapping in the new engine"
        case .manifest: return "writing homelab-app.json"
        case .signEngine: return "signing 7zz"
        case .signBundle: return "signing the app bundle"
        case .verifySignature: return "verifying the app signature"
        }
    }
}

/// Injection points used by the unit tests to force a rollback at any step.
public struct InstallationHooks {
    public var signEngine: (URL) throws -> Void
    public var signBundle: (URL) throws -> Void
    public var verifySignature: (URL) throws -> Void
    public var journalURL: URL?
    public var failAt: InstallStep?

    public init(
        signEngine: @escaping (URL) throws -> Void = EngineSigning.adHocSignEngine,
        signBundle: @escaping (URL) throws -> Void = EngineSigning.adHocSignBundle,
        verifySignature: @escaping (URL) throws -> Void = EngineSigning.verifyBundle,
        journalURL: URL? = EngineUpdateJournal.defaultURL,
        failAt: InstallStep? = nil
    ) {
        self.signEngine = signEngine
        self.signBundle = signBundle
        self.verifySignature = verifySignature
        self.journalURL = journalURL
        self.failAt = failAt
    }

    public static var live: InstallationHooks { InstallationHooks() }

    /// Mostly for tests: no signing, no journal.
    public static var dryRun: InstallationHooks {
        InstallationHooks(
            signEngine: { _ in },
            signBundle: { _ in },
            verifySignature: { _ in },
            journalURL: nil
        )
    }
}

public enum EngineInstaller {
    /// Installs an already verified universal engine and its manifest.
    ///
    /// The engine is staged inside `Contents/Resources` by the caller, then:
    /// back up 7zz → 7zz.previous, atomically replace 7zz, write the manifest,
    /// sign 7zz, sign the bundle, verify. Any failure restores the previous
    /// engine + manifest + provenance and re-signs the bundle.
    public static func install(
        stagedEngine: URL,
        newManifest: DependencyManifest,
        bundle: URL,
        hooks: InstallationHooks = .live
    ) throws -> ApplyResult {
        try newManifest.validate()

        let fileManager = FileManager.default
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let engine = resources.appendingPathComponent("7zz")
        let previous = resources.appendingPathComponent("7zz.previous")
        let manifestURL = resources.appendingPathComponent("homelab-app.json")
        let provenanceURL = resources.appendingPathComponent("engine-provenance.txt")

        guard fileManager.isExecutableFile(atPath: engine.path) else {
            throw EngineUpdateError.stepFailed(
                step: "locating the installed engine",
                reason: "\(engine.path) is missing or not executable."
            )
        }
        guard fileManager.fileExists(atPath: stagedEngine.path) else {
            throw EngineUpdateError.stepFailed(
                step: "staging the new engine",
                reason: "\(stagedEngine.path) does not exist."
            )
        }

        let previousManifestData = try? Data(contentsOf: manifestURL)
        let previousProvenanceData = try? Data(contentsOf: provenanceURL)
        let previousVersion = (try? DependencyManifest.read(from: manifestURL))?.engineVersion ?? ""

        var journal = EngineUpdateJournal(
            bundlePath: bundle.standardizedFileURL.path,
            previousVersion: previousVersion,
            targetVersion: newManifest.engineVersion ?? "",
            previousManifest: previousManifestData.flatMap { String(data: $0, encoding: .utf8) },
            previousProvenance: previousProvenanceData.flatMap { String(data: $0, encoding: .utf8) }
        )

        func saveJournal(_ phase: EngineUpdateJournal.Phase) throws {
            journal.phase = phase
            if let url = hooks.journalURL {
                try journal.write(to: url)
            }
        }

        func removeJournal() {
            if let url = hooks.journalURL {
                EngineUpdateJournal.remove(at: url)
            }
        }

        var injected = false
        func injectFailure(at step: InstallStep) throws {
            guard !injected, hooks.failAt == step else { return }
            injected = true
            throw EngineUpdateError.stepFailed(
                step: step.title,
                reason: "Injected failure for testing."
            )
        }

        var currentStep = "preparing the update"
        var swapped = false
        var manifestWritten = false
        var backupComplete = false

        do {
            try saveJournal(.prepared)

            currentStep = InstallStep.backup.title
            try? fileManager.removeItem(at: previous)
            try fileManager.copyItem(at: engine, to: previous)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: previous.path)
            backupComplete = true
            try saveJournal(.backedUp)
            try injectFailure(at: .backup)

            currentStep = InstallStep.swap.title
            try InstallationSupport.atomicInstall(source: stagedEngine, target: engine)
            swapped = true
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
            try saveJournal(.swapped)
            try injectFailure(at: .swap)

            currentStep = InstallStep.manifest.title
            try newManifest.write(to: manifestURL)
            try Data("official-binary\n".utf8).write(to: provenanceURL, options: [.atomic])
            manifestWritten = true
            try saveJournal(.manifestWritten)
            try injectFailure(at: .manifest)

            currentStep = InstallStep.signEngine.title
            try hooks.signEngine(engine)
            try injectFailure(at: .signEngine)

            currentStep = InstallStep.signBundle.title
            try hooks.signBundle(bundle)
            try injectFailure(at: .signBundle)

            currentStep = InstallStep.verifySignature.title
            try hooks.verifySignature(bundle)
            try injectFailure(at: .verifySignature)

            try saveJournal(.completed)
            removeJournal()
            return ApplyResult(
                appliedVersion: newManifest.engineVersion ?? "",
                previousEngineURL: previous,
                manifestURL: manifestURL
            )
        } catch {
            let original = error
            do {
                try? fileManager.removeItem(at: resources.appendingPathComponent("7zz.new"))
                if swapped {
                    if fileManager.fileExists(atPath: previous.path) {
                        try InstallationSupport.replaceContents(of: engine, with: previous)
                    } else {
                        throw EngineUpdateError.stepFailed(
                            step: "restoring the previous engine",
                            reason: "7zz.previous is missing."
                        )
                    }
                    if manifestWritten {
                        if let previousManifestData {
                            try previousManifestData.write(to: manifestURL, options: [.atomic])
                        } else {
                            try? fileManager.removeItem(at: manifestURL)
                        }
                        if let previousProvenanceData {
                            try previousProvenanceData.write(to: provenanceURL, options: [.atomic])
                        } else {
                            try? fileManager.removeItem(at: provenanceURL)
                        }
                    }
                    try hooks.signEngine(engine)
                } else if !backupComplete {
                    // A partial 7zz.previous would change the sealed resource set.
                    try? fileManager.removeItem(at: previous)
                }
                // Even a failure before the swap may have added 7zz.previous
                // or 7zz.new to Contents/Resources. Re-sign the bundle so the
                // on-disk app is never left with an invalid signature.
                try hooks.signBundle(bundle)
                try hooks.verifySignature(bundle)
                removeJournal()
            } catch let rollbackError {
                if let updateError = original as? EngineUpdateError {
                    throw EngineUpdateError.rollbackFailed(
                        step: currentStep,
                        reason: updateError.localizedDescription,
                        rollbackReason: rollbackError.localizedDescription
                    )
                }
                throw EngineUpdateError.rollbackFailed(
                    step: currentStep,
                    reason: original.localizedDescription,
                    rollbackReason: rollbackError.localizedDescription
                )
            }
            throw original
        }
    }
}

public enum InstallationSupport {
    /// Replaces `target` with a copy of `source`, atomically. `source` is kept.
    public static func replaceContents(of target: URL, with source: URL) throws {
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".sevenzip-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        try renameAtomically(temporary, to: target)
    }

    /// Atomically moves `source` over `target`.
    public static func atomicInstall(source: URL, target: URL) throws {
        if source.deletingLastPathComponent().standardizedFileURL != target.deletingLastPathComponent().standardizedFileURL {
            let temporary = target.deletingLastPathComponent()
                .appendingPathComponent(".sevenzip-stage-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: source, to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            try renameAtomically(temporary, to: target)
        } else {
            try renameAtomically(source, to: target)
        }
    }

    private static func renameAtomically(_ source: URL, to target: URL) throws {
        let result = source.path.withCString { sourcePath in
            target.path.withCString { targetPath in
                Darwin.rename(sourcePath, targetPath)
            }
        }
        guard result == 0 else {
            let code = errno
            throw EngineUpdateError.stepFailed(
                step: "replacing \(target.lastPathComponent)",
                reason: String(cString: strerror(code))
            )
        }
    }
}
