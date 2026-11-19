import AppKit
import Combine
import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Reads and changes the default application for the file types SevenZip
/// supports. Changes are only made in response to an explicit user toggle.
@MainActor
final class FileAssociations: ObservableObject {
    struct Entry: Identifiable {
        let extensionName: String
        let type: UTType
        let typeIdentifier: String
        let handlerID: String?
        let appName: String
        let isDefault: Bool

        var id: String { extensionName }
    }

    @Published private(set) var entries: [Entry] = []
    @Published var errorMessage: String?

    private static let extensionNames = [
        "7z", "zip", "rar", "tar", "gz", "tgz", "bz2", "tbz2",
        "xz", "txz", "lzma", "iso", "dmg", "cab"
    ]

    private var appBundleID: String? { Bundle.main.bundleIdentifier }

    init() {
        reload()
    }

    func reload() {
        let currentBundleID = appBundleID
        entries = Self.extensionNames.compactMap { name in
            guard let type = UTType(filenameExtension: name) else { return nil }
            let handler = Self.defaultHandler(for: type)
            return Entry(
                extensionName: name,
                type: type,
                typeIdentifier: type.identifier,
                handlerID: handler,
                appName: Self.appName(for: handler),
                isDefault: handler != nil && handler == currentBundleID
            )
        }
    }

    func setDefault(_ enabled: Bool, for entry: Entry) {
        guard let appBundleID else {
            errorMessage = "The app isn’t running from an application bundle, so macOS can’t make it a default handler."
            return
        }

        let type = entry.type
        let previousKey = "association.previous.\(type.identifier)"

        if enabled, let current = entry.handlerID, current != appBundleID {
            UserDefaults.standard.set(current, forKey: previousKey)
        }

        let target: String
        if enabled {
            target = appBundleID
        } else if let stored = UserDefaults.standard.string(forKey: previousKey),
                  stored != appBundleID,
                  Self.applicationURL(for: stored) != nil {
            target = stored
        } else {
            target = Self.fallbackHandler(for: type)
        }

        let status = LSSetDefaultRoleHandlerForContentType(
            type.identifier as CFString,
            .all,
            target as CFString
        )

        if status != noErr {
            errorMessage = "macOS refused to change .\(entry.extensionName) (LaunchServices error \(status))."
        } else if !enabled {
            UserDefaults.standard.removeObject(forKey: previousKey)
        }

        reload()
    }

    private static func defaultHandler(for type: UTType) -> String? {
        guard let copy = LSCopyDefaultRoleHandlerForContentType(type.identifier as CFString, .all) else {
            return nil
        }
        return copy.takeRetainedValue() as String
    }

    private static func applicationURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private static func appName(for bundleID: String?) -> String {
        guard let bundleID else { return "No application" }
        guard let url = applicationURL(for: bundleID) else { return "another app" }
        if let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func fallbackHandler(for type: UTType) -> String {
        switch type.identifier {
        case "public.iso-image", "com.apple.disk-image-udif":
            return "com.apple.DiskImageMounter"
        default:
            return "com.apple.archiveutility"
        }
    }
}
