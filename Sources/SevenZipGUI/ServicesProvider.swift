import AppKit

/// Exposes Finder's "Services" menu actions. macOS shows these under
/// right-click → Services, which is the supported way for an app to act on an
/// arbitrary selection without shipping a Finder Sync extension.
final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()

    func install() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    @objc func compressWithSevenZip(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = "No files or folders were selected." as NSString
            return
        }
        Task { @MainActor in
            AppWindowCoordinator.shared.presentWhenReady()
            try? await Task.sleep(nanoseconds: 150_000_000)
            ArchiveModel.shared.compressFromFinder(urls)
        }
    }

    @objc func extractWithSevenZip(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = "No files were selected." as NSString
            return
        }
        Task { @MainActor in
            AppWindowCoordinator.shared.presentWhenReady()
            try? await Task.sleep(nanoseconds: 150_000_000)
            ArchiveModel.shared.extractFromFinder(urls)
        }
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}
