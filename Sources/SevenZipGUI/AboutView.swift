import AppKit
import SwiftUI

/// The About panel carries the wychoi maker identity: the abacus mark, the
/// maker's blue, and a single clear link to wychoi.com. It is used both as the
/// app-menu About window and as the About tab in Settings.
struct AboutView: View {
    var compact = false

    @ObservedObject private var updates = EngineUpdateController.shared

    private let makerURL = URL(string: "https://wychoi.com")!
    private let sevenZipURL = URL(string: "https://www.7-zip.org")!
    private let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!

    var body: some View {
        ScrollView {
            VStack(spacing: compact ? 18 : 22) {
                hero
                credits
                legal
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, compact ? 20 : 28)
            .padding(.vertical, compact ? 22 : 26)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Brand.purple)
        .frame(width: compact ? nil : 540, height: compact ? nil : 520)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 11) {
            FinderWordmark(size: compact ? 30 : 34)
                .shadow(color: Brand.purple.opacity(0.12), radius: 9, y: 4)

            Text("A native 7-Zip GUI for macOS.")
                .font(AppFont.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 7) {
                BrandPill(text: "Version \(version)")
                BrandPill(text: "Universal", filled: false)
                makerPill
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// The maker credit sits in the metadata row, not in a second hero.
    private var makerPill: some View {
        Link(destination: makerURL) {
            HStack(spacing: 4) {
                AbacusGlyph(tint: Brand.makerBlue)
                    .frame(width: 12, height: 12)
                Text("by wychoi")
                    .font(AppFont.caption.weight(.medium))
            }
            .foregroundStyle(Brand.makerBlue)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Brand.makerBlue.opacity(0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Made by wychoi — open wychoi.com")
        .accessibilityLabel("Made by wychoi — open wychoi.com")
    }

    // MARK: Credits

    private var credits: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(text: "Built with")
                .padding(.horizontal, 2)

            SettingsCard {
                aboutRow("Application", value: "Finder7 \(version)")
                SettingsDivider()
                aboutRow(
                    "Engine",
                    value: updates.installedVersion == "unknown"
                        ? "Bundled 7-Zip"
                        : "7-Zip \(updates.installedVersion)",
                    detail: updates.provenanceLabel
                )
                SettingsDivider()

                SettingsRow("Engine license", subtitle: "7-Zip by Igor Pavlov") {
                    BrandLink(
                        title: "LGPL · 7-zip.org",
                        destination: sevenZipURL,
                        color: Brand.makerBlue
                    )
                }

                SettingsDivider()

                SettingsRow("App license") {
                    BrandLink(title: "GPLv3", destination: licenseURL, color: Brand.makerBlue)
                }
                SettingsDivider()
                aboutRow("Platform", value: "macOS 14+ · Universal")
            }
        }
    }

    private func aboutRow(_ title: String, value: String, detail: String? = nil) -> some View {
        SettingsRow(title, subtitle: detail) {
            Text(value)
                .font(AppFont.monoValue)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: Legal

    private var legal: some View {
        VStack(spacing: 6) {
            Text("Finder7 is an independent GUI for the official 7-Zip engine. 7-Zip is a project by Igor Pavlov; this app is not affiliated with it.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("© \(Calendar.current.component(.year, from: Date())) Wai Yin Choi. Released under the GNU GPLv3.")
                .font(AppFont.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 10)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
