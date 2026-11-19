import AppKit
import SwiftUI

struct AssociationsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var associations = FileAssociations()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(associations.entries) { entry in
                row(entry)
                    .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .frame(width: 580, height: 540)
        .tint(Brand.purple)
        .alert(
            "Couldn’t change the default app",
            isPresented: Binding(
                get: { associations.errorMessage != nil },
                set: { if !$0 { associations.errorMessage = nil } }
            )
        ) {
            Button("OK") { associations.errorMessage = nil }
        } message: {
            Text(associations.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Finder7Mark(size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("File Associations")
                    .font(.system(size: 17, weight: .semibold))
                Text("Choose which file types open in Finder7 by default.")
                    .font(AppFont.secondary)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("\(associations.entries.count) types")
                .font(AppFont.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func row(_ entry: FileAssociations.Entry) -> some View {
        HStack(spacing: 11) {
            Image(nsImage: icon(for: entry))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)

            Text(".\(entry.extensionName)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 62, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.type.localizedDescription ?? entry.typeIdentifier)
                    .font(AppFont.bodyMedium)
                    .lineLimit(1)
                Text(entry.isDefault ? "Finder7 is the default" : "Currently opens with \(entry.appName)")
                    .font(AppFont.caption)
                    .foregroundStyle(entry.isDefault ? Brand.purpleText : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            BrandSwitch(
                isOn: Binding(
                    get: { entry.isDefault },
                    set: { associations.setDefault($0, for: entry) }
                ),
                accessibilityText: "Open .\(entry.extensionName) with Finder7 by default"
            )
        }
        .padding(.vertical, 3)
    }

    private func icon(for entry: FileAssociations.Entry) -> NSImage {
        if entry.isDefault {
            if let url = Bundle.main.url(forResource: "ArchiveDoc", withExtension: "icns"),
               let image = NSImage(contentsOf: url) {
                return image
            }
            return NSApplication.shared.applicationIconImage
                ?? NSWorkspace.shared.icon(for: entry.type)
        }
        return NSWorkspace.shared.icon(for: entry.type)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text("Turning a type off restores the app that handled it before, when known; otherwise it returns to Archive Utility. macOS may ask you to confirm changes.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Refresh") { associations.reload() }
                .controlSize(.small)
        }
        .padding(12)
    }
}
