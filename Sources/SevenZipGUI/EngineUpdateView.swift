import SwiftUI

struct EngineUpdateView: View {
    var onClose: (() -> Void)? = nil

    @ObservedObject private var updates = EngineUpdateController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            SettingsCard {
                SettingsRow("Installed", subtitle: updates.provenanceLabel) {
                    Text(updates.installedVersion)
                        .font(AppFont.monoValue)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }

                SettingsDivider()

                SettingsRow("Newest release") {
                    if let check = updates.check {
                        Text(check.latestVersion)
                            .font(AppFont.monoValue)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    } else {
                        Text("Not checked")
                            .font(AppFont.secondary)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsDivider()

                SettingsRow("Last check") {
                    Text(updates.lastCheckText)
                        .font(AppFont.monoValue)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            status

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Button("Check Again") {
                    updates.checkForUpdates(force: true, present: true)
                }
                .controlSize(.large)
                .disabled(updates.isBusy)

                Spacer()

                if updates.canCancel {
                    Button("Cancel", role: .cancel) { updates.cancel() }
                        .controlSize(.large)
                }

                if updates.hasUpdate, !updates.isBusy {
                    Button("Update to \(updates.check?.latestVersion ?? "")") {
                        updates.applyUpdate()
                    }
                    .brandProminent()
                }

                if case .done = updates.phase {
                    Button("Restart Now") { updates.showRestartPrompt = true }
                        .brandProminent()
                }

                Button("Close") {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .disabled(updates.isBusy)
            }
        }
        .padding(22)
        .frame(width: 520)
        .tint(Brand.purple)
        .alert("Restart Finder7?", isPresented: $updates.showRestartPrompt) {
            Button("Later", role: .cancel) {}
            Button("Restart Now") { updates.restartApp() }
        } message: {
            Text("The new 7-Zip engine is installed and verified. Finder7 needs to restart to use it.")
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Brand.purple.opacity(0.12))
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Brand.purpleText)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("7-Zip Engine")
                    .font(.system(size: 17, weight: .semibold))
                Text("Official ip7z/7zip release, verified before installation.")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if updates.hasUpdate {
                BrandPill(text: "Update available")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if case .updating = updates.phase {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: updates.progress)
                    .progressViewStyle(.linear)
                HStack(spacing: 8) {
                    Text(updates.message)
                        .font(AppFont.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("\(Int((updates.progress * 100).rounded()))%")
                        .font(AppFont.monoValue)
                        .foregroundStyle(.secondary)
                }
            }
        } else if !updates.message.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .frame(width: 15)
                    .padding(.top, 1)
                Text(updates.message)
                    .font(AppFont.secondary)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusIcon: String {
        switch updates.phase {
        case .failed: return "exclamationmark.triangle.fill"
        case .upToDate, .done: return "checkmark.circle.fill"
        case .available: return "arrow.down.circle.fill"
        case .cancelled: return "xmark.circle"
        default: return "info.circle"
        }
    }

    private var statusColor: Color {
        switch updates.phase {
        case .failed: return .orange
        case .upToDate, .done: return .secondary
        case .available: return Brand.purpleText
        default: return .secondary
        }
    }
}
