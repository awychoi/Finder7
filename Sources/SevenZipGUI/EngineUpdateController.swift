import AppKit
import Foundation
import SevenZipCore
import SwiftUI

/// Owns the in-app update UI state. Checks are only started from an explicit
/// user action (menu or Settings); nothing runs automatically at launch.
@MainActor
final class EngineUpdateController: ObservableObject {
    static let shared = EngineUpdateController()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case updating(UpdateProgress.Phase)
        case done
        case failed
        case cancelled
    }

    @Published var phase: Phase = .idle
    @Published var check: UpdateCheck?
    @Published var progress = 0.0
    @Published var message = ""
    @Published var showRestartPrompt = false
    @Published var installedVersion: String
    @Published var provenance: String
    @Published var lastCheck: Date?

    private let service = EngineUpdateService()
    private let cache = UpdateCache()
    private var task: Task<Void, Never>?

    private init() {
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let manifest = try? DependencyManifest.read(
            from: resources.appendingPathComponent("homelab-app.json")
        )
        installedVersion = manifest?.engineVersion ?? "unknown"
        provenance = (try? String(
            contentsOf: resources.appendingPathComponent("engine-provenance.txt"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        lastCheck = cache.lastCheckDate
    }

    var hasUpdate: Bool {
        check?.updateAvailable == true
    }

    var isBusy: Bool {
        if case .checking = phase { return true }
        if case .updating = phase { return true }
        return false
    }

    var canCancel: Bool {
        guard case .updating(let step) = phase else { return false }
        switch step {
        case .downloading, .verifying, .staging, .smokeTesting:
            return true
        case .installing, .signing, .manifest, .finished:
            return false
        }
    }

    var provenanceLabel: String {
        switch provenance {
        case "official-binary": return "Official binary"
        case "source-build": return "Source build"
        case "", "unknown": return "Unknown"
        default: return provenance
        }
    }

    var lastCheckText: String {
        guard let lastCheck else { return "Never checked" }
        return lastCheck.formatted(date: .abbreviated, time: .shortened)
    }

    func present() {
        EngineUpdateWindowController.shared.show()
    }

    func checkForUpdates(force: Bool = true, present: Bool = false) {
        guard task == nil else { return }
        if present { self.present() }
        phase = .checking
        message = "Checking GitHub for a newer 7-Zip release…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.service.checkForUpdate(force: force)
                self.check = result
                self.lastCheck = result.checkedAt
                self.installedVersion = result.installedVersion
                self.refreshProvenance()
                if result.updateAvailable {
                    self.phase = .available
                    self.message = "7-Zip \(result.latestVersion) is available (you have \(result.installedVersion))."
                } else {
                    self.phase = .upToDate
                    self.message = "You're on the newest version (\(result.installedVersion))."
                }
            } catch {
                self.phase = .failed
                self.message = error.localizedDescription
            }
            self.task = nil
        }
    }

    func applyUpdate() {
        guard task == nil, let available = check, available.updateAvailable else { return }
        guard !ArchiveModel.shared.isRunning else {
            phase = .failed
            message = EngineUpdateError.archiveOperationRunning.localizedDescription
            present()
            return
        }
        present()
        progress = 0
        phase = .updating(.downloading)
        message = "Preparing the update…"
        let target = available.latestVersion
        let archiveRunning = ArchiveModel.shared.isRunning
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.service.downloadAndApply(
                    tag: target,
                    fromDirectory: nil,
                    isArchiveOperationRunning: { archiveRunning }
                ) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.progress = update.fraction
                        self.phase = .updating(update.phase)
                        self.message = update.message
                    }
                }
                self.progress = 1
                self.installedVersion = result.appliedVersion
                self.provenance = "official-binary"
                self.check = UpdateCheck(
                    installedVersion: result.appliedVersion,
                    latestVersion: result.appliedVersion,
                    updateAvailable: false,
                    checkedAt: Date(),
                    releaseURL: available.releaseURL,
                    publishedAt: available.publishedAt,
                    assetNames: available.assetNames
                )
                self.lastCheck = Date()
                self.phase = .done
                self.message = "Updated to 7-Zip \(result.appliedVersion). Restart Finder7 to use the new engine."
                self.showRestartPrompt = true
            } catch let error as EngineUpdateError {
                if case .cancelled = error {
                    self.phase = .cancelled
                    self.message = "Update cancelled. The installed engine was not changed."
                } else {
                    self.phase = .failed
                    self.message = error.localizedDescription
                }
            } catch is CancellationError {
                self.phase = .cancelled
                self.message = "Update cancelled. The installed engine was not changed."
            } catch {
                self.phase = .failed
                self.message = error.localizedDescription
            }
            self.task = nil
        }
    }

    func cancel() {
        guard canCancel else { return }
        task?.cancel()
        phase = .cancelled
        message = "Cancelling the update…"
    }

    func restartApp() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.message = "Could not relaunch Finder7: \(error.localizedDescription)"
                    self?.showRestartPrompt = false
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func refreshProvenance() {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/engine-provenance.txt")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            provenance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
