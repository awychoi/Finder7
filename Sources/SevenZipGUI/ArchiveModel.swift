import AppKit
import Combine
import Foundation

@MainActor
final class ArchiveModel: ObservableObject {
    static let shared = ArchiveModel()

    enum Mode: String, CaseIterable, Identifiable {
        case compress = "Compress"
        case extract = "Extract"

        var id: String { rawValue }
    }

    enum Level: Int, CaseIterable, Identifiable {
        case store = 0
        case fast = 1
        case normal = 5
        case maximum = 7
        case ultra = 9

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .store: return "Store"
            case .fast: return "Fast"
            case .normal: return "Normal"
            case .maximum: return "Maximum"
            case .ultra: return "Ultra"
            }
        }
    }

    // Inputs
    @Published var mode: Mode = .compress
    @Published var sources: [URL] = []
    @Published var archiveURL: URL?
    @Published var destinationURL: URL?
    @Published var outputURL: URL?
    @Published var format: ArchiveFormat = .sevenZip
    @Published var level: Level = .normal {
        didSet { optionsDidChange() }
    }
    @Published var password = "" {
        didSet { optionsDidChange() }
    }
    @Published var encryptFileNames = false {
        didSet { optionsDidChange() }
    }

    // Run state
    @Published var progress = 0.0
    @Published var statusText = ""
    @Published var isRunning = false
    @Published var logText = ""
    @Published var errorMessage: String?
    @Published var showLog = false
    @Published var showOverwritePrompt = false
    @Published var finishedURL: URL?
    @Published var finishedWithWarnings = false
    @Published var isFinished = false

    // One-click / Finder defaults
    @Published var defaultFormat: ArchiveFormat = .sevenZip {
        didSet {
            UserDefaults.standard.set(defaultFormat.rawValue, forKey: DefaultsKey.format)
            if !isRunning { format = defaultFormat }
        }
    }
    @Published var defaultLevel: Level = .normal {
        didSet {
            UserDefaults.standard.set(defaultLevel.rawValue, forKey: DefaultsKey.level)
            if !isRunning { level = defaultLevel }
        }
    }
    @Published var extractToSubfolder = true {
        didSet {
            UserDefaults.standard.set(extractToSubfolder, forKey: DefaultsKey.extractToSubfolder)
        }
    }
    @Published var quitAfterFinderAction = true {
        didSet {
            UserDefaults.standard.set(quitAfterFinderAction, forKey: DefaultsKey.quitAfterFinderAction)
        }
    }

    private enum DefaultsKey {
        static let format = "defaultArchiveFormat"
        static let level = "defaultCompressionLevel"
        static let extractToSubfolder = "extractToSubfolder"
        static let quitAfterFinderAction = "quitAfterFinderAction"
    }

    private var runner: SevenZipRunner?
    private var pendingAction: (() -> Void)?
    private var finderAction = false

    init() {
        let defaults = UserDefaults.standard
        let savedFormat = ArchiveFormat(
            rawValue: defaults.string(forKey: DefaultsKey.format) ?? ""
        ) ?? .sevenZip
        let savedLevelRaw = defaults.object(forKey: DefaultsKey.level) as? Int
        let savedLevel = savedLevelRaw.flatMap { Level(rawValue: $0) } ?? .normal

        defaultFormat = savedFormat
        defaultLevel = savedLevel
        format = savedFormat
        level = savedLevel

        if defaults.object(forKey: DefaultsKey.extractToSubfolder) != nil {
            extractToSubfolder = defaults.bool(forKey: DefaultsKey.extractToSubfolder)
        }
        if defaults.object(forKey: DefaultsKey.quitAfterFinderAction) != nil {
            quitAfterFinderAction = defaults.bool(forKey: DefaultsKey.quitAfterFinderAction)
        }
    }

    /// Restore the user-facing defaults without touching file associations or
    /// an archive that is already in progress.
    func resetDefaults() {
        guard !isRunning else { return }
        defaultFormat = .sevenZip
        defaultLevel = .normal
        extractToSubfolder = true
        quitAfterFinderAction = true
    }

    // MARK: Derived values

    var suggestedOutputURL: URL? {
        guard let first = sources.first else { return nil }
        let directory = first.deletingLastPathComponent()
        let name = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            ? first.lastPathComponent
            : first.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(name).\(format.fileExtension)")
    }

    var effectiveOutputURL: URL? {
        outputURL ?? suggestedOutputURL
    }

    var suggestedDestinationURL: URL? {
        guard let archive = archiveURL else { return nil }
        return Self.subfolderDestination(for: archive)
    }

    static func subfolderDestination(for archive: URL) -> URL {
        let name = archive.lastPathComponent
        var base = name
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz"] where name.lowercased().hasSuffix(suffix) {
            base = String(name.dropLast(suffix.count))
            break
        }
        if base == name {
            base = archive.deletingPathExtension().lastPathComponent
        }
        if base.isEmpty { base = "Extracted" }
        return archive.deletingLastPathComponent().appendingPathComponent(base, isDirectory: true)
    }

    var effectiveDestinationURL: URL? {
        destinationURL ?? suggestedDestinationURL
    }

    var canRun: Bool {
        if isRunning { return false }
        switch mode {
        case .compress: return !sources.isEmpty && effectiveOutputURL != nil
        case .extract: return archiveURL != nil
        }
    }

    var actionTitle: String {
        mode == .compress ? "Create Archive" : "Extract"
    }

    var idleHint: String {
        switch mode {
        case .compress:
            return sources.isEmpty ? "Drop files or folders to get started." : "Ready to compress \(sources.count) item\(sources.count == 1 ? "" : "s")."
        case .extract:
            return archiveURL == nil ? "Drop an archive, or choose one." : "Ready to extract."
        }
    }

    // MARK: Input handling

    func setMode(_ newMode: Mode) {
        guard !isRunning else { return }
        mode = newMode
        statusText = ""
        progress = 0
        finishedURL = nil
        isFinished = false
    }

    func addSources(_ urls: [URL]) {
        guard !isRunning else { return }
        var seen = Set(sources.map(\.standardizedFileURL.path))
        for url in urls where !seen.contains(url.standardizedFileURL.path) {
            sources.append(url)
            seen.insert(url.standardizedFileURL.path)
        }
        outputURL = nil
        statusText = ""
        progress = 0
        finishedURL = nil
        isFinished = false
    }

    func removeSource(_ url: URL) {
        guard !isRunning else { return }
        sources.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        outputURL = nil
        statusText = ""
        progress = 0
        finishedURL = nil
        isFinished = false
    }

    func clearSources() {
        guard !isRunning else { return }
        sources.removeAll()
        outputURL = nil
        statusText = ""
        progress = 0
        finishedURL = nil
        isFinished = false
    }

    func setArchive(_ url: URL) {
        guard !isRunning else { return }
        archiveURL = url
        destinationURL = nil
        statusText = ""
        progress = 0
        finishedURL = nil
        isFinished = false
    }

    func drop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if mode == .extract {
            if let archive = urls.first(where: ArchiveFormat.looksLikeArchive) {
                setArchive(archive)
            } else {
                setArchive(urls[0])
            }
        } else {
            addSources(urls)
        }
    }

    func chooseSources() {
        let panel = NSOpenPanel()
        panel.title = "Choose Files or Folders"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        if panel.runModal() == .OK {
            addSources(panel.urls)
        }
    }

    func chooseArchive() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Archive"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            setArchive(url)
        }
    }

    func chooseOutput() {
        invalidateResult()
        let panel = NSSavePanel()
        panel.title = "Save Archive As"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = effectiveOutputURL?.lastPathComponent ?? "Archive.\(format.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            outputURL = url
        }
    }

    func chooseDestination() {
        invalidateResult()
        let panel = NSOpenPanel()
        panel.title = "Choose Destination Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let current = effectiveDestinationURL, current.hasDirectoryPath,
           FileManager.default.fileExists(atPath: current.path) {
            panel.directoryURL = current
        }
        if panel.runModal() == .OK, let url = panel.url {
            destinationURL = url
        }
    }

    func formatDidChange() {
        invalidateResult()
        guard let output = outputURL else { return }
        outputURL = output.deletingPathExtension().appendingPathExtension(format.fileExtension)
    }

    private func invalidateResult() {
        guard !isRunning else { return }
        isFinished = false
        finishedURL = nil
        finishedWithWarnings = false
        progress = 0
        statusText = ""
    }

    /// Editing an option after a finished run returns the window to its
    /// pre-run state, so the primary button is an action again.
    private func optionsDidChange() {
        guard !isRunning, isFinished else { return }
        invalidateResult()
    }

    func startOver() {
        guard !isRunning else { return }
        sources.removeAll()
        archiveURL = nil
        destinationURL = nil
        outputURL = nil
        password = ""
        isFinished = false
        finishedURL = nil
        finishedWithWarnings = false
        progress = 0
        statusText = ""
        errorMessage = nil
    }

    // MARK: Finder one-click actions

    /// Finder service: compress the selection next to itself using the saved defaults.
    func compressFromFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isRunning else {
            NSSound.beep()
            statusText = "Another archive operation is running."
            return
        }

        finderAction = true
        let directory = finderDirectory(for: urls)
        let base: String
        if urls.count == 1, !Self.isDirectory(urls[0]) {
            base = urls[0].deletingPathExtension().lastPathComponent
        } else if urls.count == 1 {
            base = urls[0].lastPathComponent
        } else {
            base = "Archive"
        }

        let output = Self.uniqueFile(
            in: directory,
            base: base,
            fileExtension: defaultFormat.fileExtension
        )

        mode = .compress
        sources = urls
        format = defaultFormat
        level = defaultLevel
        password = ""
        encryptFileNames = false
        outputURL = output
        statusText = ""
        progress = 0
        finishedURL = nil
        finishedWithWarnings = false
        isFinished = false

        performCompress(to: output)
    }

    /// Finder service: extract the selected archive(s) next to themselves.
    func extractFromFinder(_ urls: [URL]) {
        let archives = urls.filter { ArchiveFormat.looksLikeArchive($0) && !Self.isDirectory($0) }
        guard !archives.isEmpty else {
            errorMessage = "No archive files were selected. Choose a .7z, .zip, .rar, .tar, or similar file."
            return
        }
        guard !isRunning else {
            NSSound.beep()
            statusText = "Another archive operation is running."
            return
        }
        finderAction = true
        runFinderExtraction(archives)
    }

    private func runFinderExtraction(_ archives: [URL]) {
        mode = .extract
        archiveURL = archives[0]
        destinationURL = finderDestination(for: archives[0])
        password = ""
        isRunning = true
        progress = 0
        logText = ""
        statusText = archives.count == 1
            ? "Extracting…"
            : "Extracting 1 of \(archives.count)…"
        finishedURL = nil
        finishedWithWarnings = false
        isFinished = false

        let runner = SevenZipRunner()
        self.runner = runner
        let total = Double(archives.count)

        Task {
            var failures: [String] = []
            var warnings = false
            var wasCancelled = false

            for (index, archive) in archives.enumerated() {
                if runner.isCancelled {
                    wasCancelled = true
                    break
                }

                let destination = self.finderDestination(for: archive)
                do {
                    try FileManager.default.createDirectory(
                        at: destination,
                        withIntermediateDirectories: true
                    )
                } catch {
                    failures.append("\(archive.lastPathComponent): \(error.localizedDescription)")
                    continue
                }

                if total > 1 {
                    self.statusText = "Extracting \(index + 1) of \(Int(total)): \(archive.lastPathComponent)"
                }

                do {
                    let result = try await runner.run(
                        arguments: SevenZipCommand.extract(
                            archive: archive,
                            destination: destination,
                            password: ""
                        )
                    ) { percent in
                        Task { @MainActor in
                            guard self.isRunning else { return }
                            self.progress = (Double(index) + percent / 100) / total
                        }
                    }
                    warnings = warnings || result.hadWarnings
                    self.logText = result.output
                } catch let error as SevenZipError {
                    if case .cancelled = error {
                        wasCancelled = true
                        break
                    }
                    failures.append("\(archive.lastPathComponent): \(error.localizedDescription)")
                } catch {
                    failures.append("\(archive.lastPathComponent): \(error.localizedDescription)")
                }
            }

            self.isRunning = false
            self.runner = nil

            if wasCancelled {
                self.statusText = "Cancelled"
                self.progress = 0
                self.isFinished = false
            } else if failures.isEmpty {
                self.progress = 1
                self.statusText = warnings
                    ? "Done with warnings"
                    : "Done"
                self.finishedWithWarnings = warnings
                self.finishedURL = archives.count == 1
                    ? self.destinationURL
                    : self.finderDestination(for: archives[0])
                self.isFinished = true
                self.finishFinderAction()
            } else {
                self.isFinished = false
                self.finderAction = false
                self.progress = 0
                self.statusText = "Couldn’t extract \(failures.count) of \(archives.count) archive\(archives.count == 1 ? "" : "s")"
                self.errorMessage = failures.joined(separator: "\n\n")
            }
        }
    }

    private func finderDirectory(for urls: [URL]) -> URL {
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL })
        return parents.count == 1 ? parents.first! : urls[0].deletingLastPathComponent()
    }

    private func finderDestination(for archive: URL) -> URL {
        extractToSubfolder
            ? Self.subfolderDestination(for: archive)
            : archive.deletingLastPathComponent()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func uniqueFile(in directory: URL, base: String, fileExtension ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    // MARK: Actions

    func run() {
        guard !isRunning else { return }
        finderAction = false
        errorMessage = nil
        switch mode {
        case .compress:
            beginCompress()
        case .extract:
            beginExtract()
        }
    }

    private func beginCompress() {
        guard !sources.isEmpty else {
            errorMessage = "Add at least one file or folder to compress."
            return
        }
        guard let output = effectiveOutputURL else { return }

        if FileManager.default.fileExists(atPath: output.path) {
            pendingAction = { [weak self] in self?.performCompress(to: output) }
            showOverwritePrompt = true
        } else {
            performCompress(to: output)
        }
    }

    private func performCompress(to output: URL) {
        let arguments = SevenZipCommand.compress(
            sources: sources,
            output: output,
            format: format,
            level: level.rawValue,
            password: password,
            encryptFileNames: encryptFileNames
        )
        perform(arguments: arguments, verb: "Compressing", output: output)
    }

    private func beginExtract() {
        guard let archive = archiveURL else {
            errorMessage = "Choose an archive to extract."
            return
        }
        guard let destination = effectiveDestinationURL else { return }

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not create the destination folder: \(error.localizedDescription)"
            return
        }

        let arguments = SevenZipCommand.extract(
            archive: archive,
            destination: destination,
            password: password
        )
        perform(arguments: arguments, verb: "Extracting", output: destination)
    }

    private func perform(arguments: [String], verb: String, output: URL) {
        isRunning = true
        progress = 0
        logText = ""
        statusText = "\(verb)…"
        finishedURL = nil
        finishedWithWarnings = false
        isFinished = false

        let runner = SevenZipRunner()
        self.runner = runner

        Task {
            do {
                let result = try await runner.run(arguments: arguments) { percent in
                    Task { @MainActor in
                        guard self.isRunning else { return }
                        self.progress = max(self.progress, percent / 100)
                        self.statusText = "\(verb)… \(Int(percent))%"
                    }
                }
                self.progress = 1
                self.statusText = result.hadWarnings ? "Done with warnings" : "Done"
                self.logText = result.output
                self.finishedURL = output
                self.finishedWithWarnings = result.hadWarnings
                self.isFinished = true
                self.isRunning = false
                self.runner = nil
                self.finishFinderAction()
            } catch {
                self.isRunning = false
                self.runner = nil
                self.isFinished = false
                self.finderAction = false
                if let sevenZipError = error as? SevenZipError, case .cancelled = sevenZipError {
                    self.statusText = "Cancelled"
                    self.progress = 0
                } else {
                    self.statusText = "Failed"
                    self.progress = 0
                    if let sevenZipError = error as? SevenZipError,
                       case .failed(_, let output) = sevenZipError {
                        self.logText = output
                    }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        statusText = "Cancelling…"
        finderAction = false
        runner?.cancel()
    }

    /// Finder actions auto-close by default. Failures keep the window open so
    /// the error is visible and the user can retry (for example, with a password).
    private func finishFinderAction() {
        guard finderAction else { return }
        finderAction = false
        guard quitAfterFinderAction else {
            AppWindowCoordinator.shared.present()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    func confirmPending() {
        let action = pendingAction
        pendingAction = nil
        action?()
    }

    func dismissPending() {
        pendingAction = nil
    }

    func revealFinished() {
        guard let finishedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([finishedURL])
    }
}
