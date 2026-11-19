import AppKit
import SwiftUI

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general
        case finder
        case engine
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .finder: return "Finder"
            case .engine: return "Engine"
            case .about: return "About"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .finder: return "folder"
            case .engine: return "shippingbox"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selection: Tab

    init(initialTab: Tab = .general) {
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.8)

            Group {
                switch selection {
                case .general:
                    GeneralSettingsView()
                case .finder:
                    FinderSettingsView()
                case .engine:
                    EngineSettingsView()
                case .about:
                    AboutView(compact: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 580, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Brand.purple)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11.5, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(selection == tab ? Brand.purpleText : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(
                            selection == tab ? Brand.purpleText.opacity(0.13) : Color.clear
                        )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @EnvironmentObject private var model: ArchiveModel

    var body: some View {
        SettingsPage {
            SettingsSection(
                "Compression defaults",
                footnote: "Used by Finder one-click actions and as the starting values in the main window."
            ) {
                SettingsRow("Default format") {
                    Picker("Default format", selection: $model.defaultFormat) {
                        ForEach(ArchiveFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 130)
                }

                SettingsDivider()

                SettingsRow("Compression level") {
                    Picker("Compression level", selection: $model.defaultLevel) {
                        ForEach(ArchiveModel.Level.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            HStack {
                Spacer()
                Button("Reset Settings") {
                    model.resetDefaults()
                }
                .help("Restore the default format, level, and Finder action behavior")
            }

            SettingsHint(text: "Finder7 never changes your archives without an explicit action. Settings are stored locally on this Mac.")
        }
        .tint(Brand.purple)
    }
}

// MARK: - Finder

private struct FinderSettingsView: View {
    @EnvironmentObject private var model: ArchiveModel
    @State private var showAssociations = false

    var body: some View {
        SettingsPage {
            SettingsSection(
                "One-click actions",
                footnote: "macOS controls the per-service checkboxes. If the items are hidden, enable them in System Settings → Keyboard → Keyboard Shortcuts → Services."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "cursorarrow.click.2")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Brand.purpleText)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Right-click a selection in Finder, then choose Services.")
                                .font(AppFont.body)
                                .fixedSize(horizontal: false, vertical: true)

                            serviceLine("Compress with Finder7", systemImage: "archivebox")
                            serviceLine("Extract with Finder7", systemImage: "arrow.down.doc")

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                                Text("Services registered with Finder")
                                    .font(AppFont.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)

                            HStack(spacing: 8) {
                                Button("Refresh Finder Menu") {
                                    ServicesProvider.shared.install()
                                }
                                .controlSize(.small)
                                Button("Open Keyboard Settings…") {
                                    openKeyboardSettings()
                                }
                                .controlSize(.small)
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(16)
            }

            SettingsSection(
                "Action behavior",
                footnote: "These apply to the Finder services, not to a run started in the main window."
            ) {
                SettingsRow(
                    "Create a folder for each archive",
                    subtitle: "Extract into a folder named after the archive."
                ) {
                    BrandSwitch(
                        isOn: $model.extractToSubfolder,
                        accessibilityText: "Create a folder for each archive"
                    )
                }

                SettingsDivider()

                SettingsRow(
                    "Quit after a Finder action",
                    subtitle: "Turn off to keep the window open when the action finishes."
                ) {
                    BrandSwitch(
                        isOn: $model.quitAfterFinderAction,
                        accessibilityText: "Quit after a Finder action"
                    )
                }
            }

            SettingsSection(
                "File associations",
                footnote: "Uses the same macOS default-app settings as Finder’s Get Info. Turning a type off restores the previous handler when known."
            ) {
                SettingsRow(
                    "Archive types",
                    subtitle: "Choose which file types open in Finder7."
                ) {
                    Button("Manage…") { showAssociations = true }
                }
            }
        }
        .tint(Brand.purple)
        .sheet(isPresented: $showAssociations) {
            AssociationsView()
        }
    }

    private func serviceLine(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(title)
                .font(AppFont.secondary)
        }
    }

    private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Engine

private struct EngineSettingsView: View {
    @ObservedObject private var updates = EngineUpdateController.shared

    var body: some View {
        SettingsPage {
            SettingsSection(
                "Installed engine",
                footnote: "Finder7 checks the official ip7z/7zip GitHub release on demand. Updates are downloaded, verified, re-signed, and installed into this app bundle."
            ) {
                HStack(spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Brand.purple.opacity(0.12))
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Brand.purpleText)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("7-Zip \(updates.installedVersion)")
                            .font(.system(size: 16, weight: .semibold))
                            .monospacedDigit()
                        Text("\(updates.provenanceLabel) · Last check: \(updates.lastCheckText)")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Button("Check Now") {
                        updates.checkForUpdates(force: true, present: false)
                    }
                    .controlSize(.large)
                    .disabled(updates.isBusy)

                    if updates.hasUpdate {
                        Button("Update…") {
                            updates.present()
                        }
                        .brandProminent()
                    }
                }
                .padding(16)

                SettingsDivider()

                HStack(alignment: .top, spacing: 10) {
                    engineStatusIcon
                        .frame(width: 16)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(engineStatusTitle)
                            .font(AppFont.bodyMedium)
                        if !engineStatusDetail.isEmpty {
                            Text(engineStatusDetail)
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if case .updating = updates.phase {
                            ProgressView(value: updates.progress)
                                .progressViewStyle(.linear)
                                .padding(.top, 3)
                        }
                    }

                    Spacer(minLength: 8)
                }
                .padding(16)
            }

            SettingsSection("Update source") {
                SettingsRow("Repository", subtitle: "Release source for the bundled engine") {
                    BrandLink(
                        title: "ip7z/7zip",
                        destination: URL(string: "https://github.com/ip7z/7zip")!
                    )
                }

                SettingsDivider()

                SettingsRow("Engine license") {
                    BrandLink(
                        title: "LGPL · 7-zip.org",
                        destination: URL(string: "https://www.7-zip.org")!
                    )
                }
            }
        }
        .tint(Brand.purple)
    }

    @ViewBuilder
    private var engineStatusIcon: some View {
        switch updates.phase {
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .upToDate, .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .checking, .updating:
            ProgressView()
                .controlSize(.small)
        case .available:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Brand.purpleText)
        default:
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
        }
    }

    private var engineStatusTitle: String {
        switch updates.phase {
        case .idle:
            return updates.hasUpdate
                ? "A newer engine is available."
                : "Ready to check for updates."
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "You’re on the newest version."
        case .available:
            return "7-Zip \(updates.check?.latestVersion ?? "") is available."
        case .updating:
            return "Installing the update…"
        case .done:
            return "Update installed."
        case .failed:
            return "Update failed."
        case .cancelled:
            return "Update cancelled."
        }
    }

    private var engineStatusDetail: String {
        switch updates.phase {
        case .idle, .cancelled:
            return updates.message
        case .done:
            return "Restart Finder7 to use the new engine."
        default:
            return updates.message
        }
    }
}
