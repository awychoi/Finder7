import AppKit
import SevenZipCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        ServicesProvider.shared.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A crash between the engine swap and the final signature leaves a
        // journal. Recover it before the user starts an archive operation.
        Task.detached {
            let outcome = EngineUpdateRecovery.recoverIfNeeded(bundle: Bundle.main.bundleURL)
            if case .failed(let reason) = outcome {
                FileHandle.standardError.write(
                    Data("SevenZip: could not recover an interrupted update: \(reason)\n".utf8)
                )
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindowCoordinator.shared.present()
        return true
    }

    /// Handles Finder's "Open With" / double-click for the document types in Info.plist.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let archive = urls.first(where: ArchiveFormat.looksLikeArchive) ?? urls.first else {
            return
        }
        Task { @MainActor in
            let model = ArchiveModel.shared
            model.setMode(.extract)
            model.setArchive(archive)
            NSApp.activate()
        }
    }
}
