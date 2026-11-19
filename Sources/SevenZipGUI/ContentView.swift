import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ArchiveModel
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var updates = EngineUpdateController.shared
    @State private var isTargeted = false
    @State private var revealPassword = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.8)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    sourceHeading
                    sourcePanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                VStack(spacing: 12) {
                    optionsPanel
                    destinationPanel
                    summaryPanel
                    Spacer(minLength: 0)
                }
                .frame(width: 320)
                .padding(.top, 23)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider().opacity(0.8)
            footer
        }
        .frame(minWidth: 880, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Brand.purple)
        .alert("Replace existing archive?", isPresented: $model.showOverwritePrompt) {
            Button("Cancel", role: .cancel) { model.dismissPending() }
            Button("Replace", role: .destructive) { model.confirmPending() }
        } message: {
            Text("“\(model.effectiveOutputURL?.lastPathComponent ?? "Archive")” already exists. Replacing it can’t be undone.")
        }
        .alert(
            "Couldn’t finish",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $model.showLog) { logSheet }
    }

    // MARK: Header

    /// The wordmark is the header: “Finder” with the paper-crease 7 sitting in
    /// the 7’s place. The standalone tile is the app icon, so there is no second
    /// logo competing with it here.
    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                FinderWordmark(size: 22)
                Text("7-Zip for macOS")
                    .font(AppFont.secondary)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 1)
            }

            Spacer(minLength: 16)

            if updates.hasUpdate {
                Button {
                    updates.present()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Update \(updates.check?.latestVersion ?? "")")
                    }
                    .font(AppFont.caption.weight(.semibold))
                    .foregroundStyle(Brand.purpleText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Brand.purpleText.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("A newer 7-Zip engine is available")
            }

            modeSwitch

            Divider()
                .frame(height: 22)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// A branded two-segment switch. The native segmented picker renders with
    /// the system accent, which made the selected mode ambiguous in dark mode;
    /// this keeps the selected mode filled with Finder7 purple at all times.
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            ForEach(ArchiveModel.Mode.allCases) { mode in
                Button {
                    model.setMode(mode)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode == .compress ? "archivebox" : "arrow.down.doc")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(model.mode == mode ? .white : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(model.mode == mode ? Brand.purple : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                .help(mode == .compress ? "Create an archive from files" : "Extract an existing archive")
            }
        }
        .padding(3)
        .frame(width: 196)
        .background(
            RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.75)
        )
        .disabled(model.isRunning)
        .animation(.easeOut(duration: 0.12), value: model.mode)
    }

    private var formatSwitch: some View {
        HStack(spacing: 2) {
            ForEach(ArchiveFormat.allCases) { format in
                Button {
                    model.format = format
                    model.formatDidChange()
                } label: {
                    Text(format.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.format == format ? .white : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.format == format ? Brand.purple : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.format == format ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.75)
        )
        .help("Archive format")
        .animation(.easeOut(duration: 0.12), value: model.format)
    }

    private var sourceHeading: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionEyebrow(text: model.mode == .compress ? "Files & folders" : "Archive")
            Spacer()
            if model.mode == .compress, !model.sources.isEmpty {
                Text("\(model.sources.count) item\(model.sources.count == 1 ? "" : "s")")
                    .font(AppFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            } else if model.mode == .extract, model.archiveURL != nil {
                Text("Ready")
                    .font(AppFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Source

    private var isDropZoneVisible: Bool {
        model.mode == .compress ? model.sources.isEmpty : model.archiveURL == nil
    }

    private var sourcePanel: some View {
        Panel(padding: 0) {
            Group {
                if model.mode == .compress {
                    if model.sources.isEmpty {
                        emptyDropZone(
                            title: "Drop files or folders",
                            subtitle: "They’ll be added to a new archive",
                            actionTitle: "Choose Files…"
                        ) { model.chooseSources() }
                    } else {
                        sourceList
                    }
                } else if let archive = model.archiveURL {
                    archivePane(archive)
                } else {
                    emptyDropZone(
                        title: "Drop an archive",
                        subtitle: "7z, ZIP, RAR, TAR and many more",
                        actionTitle: "Choose Archive…"
                    ) { model.chooseArchive() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Brand.purple.opacity(isTargeted ? 0.05 : 0))
        )
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Brand.purple, lineWidth: 2)
            } else if isDropZoneVisible {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .inset(by: 5)
                    .strokeBorder(
                        Brand.purpleText.opacity(0.30),
                        style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .dropDestination(for: URL.self) { urls, _ in
            model.drop(urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.12)) { isTargeted = targeted }
        }
    }

    private func emptyDropZone(
        title: String,
        subtitle: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .fill(Brand.purple.opacity(0.10))
                    .frame(width: 86, height: 86)
                Finder7Mark(size: 56)
                    .shadow(color: Brand.purple.opacity(0.22), radius: 9, y: 4)
            }

            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(subtitle)
                    .font(AppFont.body)
                    .foregroundStyle(.secondary)
            }

            Button(actionTitle, action: action)
                .brandProminent()
                .disabled(model.isRunning)

            Text("or drag and drop")
                .font(AppFont.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.sources, id: \.self) { url in
                        sourceRow(url)
                        if url != model.sources.last {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack(spacing: 14) {
                Button {
                    model.chooseSources()
                } label: {
                    Label("Add Files…", systemImage: "plus")
                }
                .brandLink()
                .disabled(model.isRunning)

                Spacer(minLength: 8)

                Text(sourceSummary)
                    .font(AppFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button("Clear") { model.clearSources() }
                    .brandLink()
                    .disabled(model.isRunning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func sourceRow(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(AppFont.bodyMedium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(sizeText(for: url))
                        .monospacedDigit()
                    Text("·")
                    Text(url.deletingLastPathComponent().path)
                        .font(AppFont.mono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                model.removeSource(url)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove from list")
            .accessibilityLabel("Remove \(url.lastPathComponent)")
            .disabled(model.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func archivePane(_ archive: URL) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: archive.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(archive.lastPathComponent)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(archive.deletingLastPathComponent().path)
                        .font(AppFont.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(archive.deletingLastPathComponent().path)
                    HStack(spacing: 8) {
                        BrandPill(text: formatBadge(for: archive))
                        Text(sizeText(for: archive))
                            .font(AppFont.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Button("Change…") { model.chooseArchive() }
                    .disabled(model.isRunning)
            }
            .padding(16)

            Divider()

            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(Brand.purpleText)
                Text("Drop a different archive here")
                    .font(AppFont.bodyMedium)
                Text("The current selection will be replaced.")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }

    // MARK: Right column

    private var optionsPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 11) {
                PanelHeader(title: "Options", systemImage: "slider.horizontal.3")

                if model.mode == .compress {
                    formatSwitch

                    HStack {
                        Text("Compression")
                            .font(AppFont.body)
                        Spacer(minLength: 8)
                        Picker("Compression", selection: $model.level) {
                            ForEach(ArchiveModel.Level.allCases) { level in
                                Text(level.title).tag(level)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 128)
                        .help("Higher levels compress more and take longer")
                    }

                    passwordRow

                    if model.format == .sevenZip {
                        Button {
                            model.encryptFileNames.toggle()
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: model.encryptFileNames ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(
                                        model.encryptFileNames ? Brand.purpleText : Color.secondary
                                    )
                                Text("Hide file names")
                                    .font(AppFont.secondary)
                                    .foregroundStyle(.primary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hide file names")
                        .accessibilityValue(model.encryptFileNames ? "On" : "Off")
                        .help("Encrypt the list of filenames in the archive (7z only)")
                    }
                } else {
                    passwordRow

                    Text("Required for encrypted archives.")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(model.isRunning)
        }
    }

    private var passwordRow: some View {
        HStack(spacing: 6) {
            Text("Password")
                .font(AppFont.body)

            Spacer(minLength: 8)

            Group {
                if revealPassword {
                    TextField("Optional", text: $model.password)
                } else {
                    SecureField("Optional", text: $model.password)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)

            Button {
                revealPassword.toggle()
            } label: {
                Image(systemName: revealPassword ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(revealPassword ? "Hide password" : "Show password")
            .accessibilityLabel(revealPassword ? "Hide password" : "Show password")
        }
    }

    private var destinationPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    PanelHeader(
                        title: model.mode == .compress ? "Save to" : "Extract to",
                        systemImage: "folder"
                    )
                    Spacer()
                    Button("Change…") {
                        if model.mode == .compress {
                            model.chooseOutput()
                        } else {
                            model.chooseDestination()
                        }
                    }
                    .brandLink()
                    .controlSize(.small)
                    .disabled(model.isRunning)
                }

                Text(destinationPath)
                    .font(AppFont.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(destinationPath)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var summaryPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                PanelHeader(title: "Summary", systemImage: "list.bullet.rectangle")

                VStack(spacing: 8) {
                    if model.mode == .compress {
                        summaryRow("Items", "\(model.sources.count)")
                        summaryRow("Size", sourceByteSummary)
                        summaryRow("Format", model.format.title)
                        summaryRow("Level", model.level.title)
                    } else {
                        summaryRow("Archive", model.archiveURL?.lastPathComponent ?? "—")
                        summaryRow("Format", archiveFormatLabel)
                        summaryRow("Destination", model.effectiveDestinationURL?.lastPathComponent ?? "—")
                    }
                }
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(AppFont.secondary)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 9) {
            if model.isRunning {
                HStack(spacing: 10) {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .animation(.easeOut(duration: 0.15), value: model.progress)
                    Text("\(Int((model.progress * 100).rounded()))%")
                        .font(AppFont.monoValue)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }

            HStack(spacing: 12) {
                statusView

                Spacer(minLength: 12)

                if !model.logText.isEmpty, !model.isRunning {
                    Button("Log") { model.showLog = true }
                        .brandLink()
                        .help("Show the 7-Zip output")
                }

                if model.isRunning {
                    Button("Cancel") { model.cancel() }
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                } else if model.isFinished {
                    Button(model.mode == .compress ? "New Archive" : "New") {
                        model.startOver()
                    }
                    .controlSize(.large)
                    Button("Show in Finder") { model.revealFinished() }
                        .brandProminent()
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.actionTitle) { model.run() }
                        .brandProminent()
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canRun)
                        .help(model.mode == .compress ? "Create the archive" : "Extract the archive")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusView: some View {
        if model.isRunning {
            Image(systemName: "gearshape.2.fill")
                .foregroundStyle(Brand.purpleText)
                .frame(width: 16)
            Text(model.statusText.isEmpty ? "Working…" : model.statusText)
                .font(AppFont.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if model.isFinished, let finished = model.finishedURL {
            Image(systemName: model.finishedWithWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(model.finishedWithWarnings ? .orange : .green)
                .frame(width: 16)
            Text(model.statusText.isEmpty ? "Done" : model.statusText)
                .font(AppFont.bodyMedium)
            Text(finished.lastPathComponent)
                .font(AppFont.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            Text(model.idleHint)
                .font(AppFont.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Log sheet

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PanelHeader(title: "7-Zip Output", systemImage: "terminal")
                Text("Raw output from 7zz")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { copyLog() }
                    .controlSize(.small)
                    .disabled(model.logText.isEmpty)
                Button("Close") { model.showLog = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                Text(model.logText.isEmpty ? "No output yet." : model.logText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
        }
        .frame(width: 640, height: 420)
        .tint(Brand.purple)
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.logText, forType: .string)
    }

    // MARK: Helpers

    private var destinationPath: String {
        if model.mode == .compress {
            return model.effectiveOutputURL?.path ?? "No destination selected"
        }
        return model.effectiveDestinationURL?.path ?? "No destination selected"
    }

    private var sourceSummary: String {
        let items = model.sources.count
        guard items > 0 else { return "No items" }
        return "\(items) item\(items == 1 ? "" : "s") · \(sourceByteSummary)"
    }

    private var sourceByteSummary: String {
        let bytes = model.sources.compactMap { fileSize(for: $0) }.reduce(0, +)
        guard bytes > 0 else { return "—" }
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    private var archiveFormatLabel: String {
        guard let archive = model.archiveURL else { return "—" }
        return formatBadge(for: archive)
    }

    private func formatBadge(for archive: URL) -> String {
        let name = archive.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return "TAR.GZ" }
        if name.hasSuffix(".tar.bz2") { return "TAR.BZ2" }
        if name.hasSuffix(".tar.xz") { return "TAR.XZ" }
        let ext = archive.pathExtension.uppercased()
        return ext.isEmpty ? "ARCHIVE" : ext
    }

    private func sizeText(for url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return "—"
        }
        if values.isDirectory == true { return "Folder" }
        guard let size = values.fileSize else { return "—" }
        return Self.byteFormatter.string(fromByteCount: Int64(size))
    }

    private func fileSize(for url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return nil
        }
        if values.isDirectory == true { return nil }
        guard let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter
    }()
}
