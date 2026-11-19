import AppKit
import SwiftUI

/// Renders the app's views off-screen for README screenshots and layout checks.
/// Usage: SevenZipGUI --snapshot /path/to/preview.png
enum Snapshot {
    @MainActor
    static func render(
        to path: String,
        mode: ArchiveModel.Mode = .compress,
        finished: Bool = false,
        empty: Bool = false
    ) -> Bool {
        let fileManager = FileManager.default
        let demoRoot = URL(fileURLWithPath: "/tmp/Finder7 Demo", isDirectory: true)
        try? fileManager.removeItem(at: demoRoot)
        try? fileManager.createDirectory(at: demoRoot, withIntermediateDirectories: true)

        let documents = demoRoot.appendingPathComponent("Documents", isDirectory: true)
        let photos = demoRoot.appendingPathComponent("Photos", isDirectory: true)
        let notes = demoRoot.appendingPathComponent("notes.txt")
        let invoice = demoRoot.appendingPathComponent("Invoice.pdf")
        try? fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: photos, withIntermediateDirectories: true)
        try? Data("Some notes\n".utf8).write(to: notes)
        try? Data("%PDF-1.4\n".utf8).write(to: invoice)

        let model = ArchiveModel()
        model.mode = mode
        if mode == .compress {
            if !empty {
                model.sources = [documents, photos, notes, invoice]
            }
            model.format = .sevenZip
            model.level = .maximum
        } else {
            model.setArchive(demoRoot.appendingPathComponent("Documents.7z"))
        }
        model.statusText = ""

        if finished {
            model.isFinished = true
            model.finishedURL = demoRoot.appendingPathComponent("Documents.7z")
            model.statusText = "Done"
            model.progress = 1
        }

        let view = ContentView()
            .environmentObject(model)
            .frame(width: 920, height: 660)
            .background(Color(nsColor: .windowBackgroundColor))

        defer { try? fileManager.removeItem(at: demoRoot) }

        return renderHosted(view, width: 920, height: 660, path: path)
    }

    @MainActor
    static func renderSettings(to path: String, tab: SettingsView.Tab = .general) -> Bool {
        let model = ArchiveModel()
        let view = SettingsView(initialTab: tab)
            .environmentObject(model)
            .background(Color(nsColor: .windowBackgroundColor))
        return renderHosted(view, width: 580, height: 560, path: path)
    }

    @MainActor
    static func renderAbout(to path: String) -> Bool {
        let view = AboutView()
            .background(Color(nsColor: .windowBackgroundColor))
        return renderHosted(view, width: 540, height: 520, path: path)
    }

    @MainActor
    static func renderUpdate(to path: String) -> Bool {
        let view = ScrollView {
            EngineUpdateView()
                .frame(minHeight: 300)
        }
        .frame(width: 520, height: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        return renderHosted(view, width: 520, height: 300, path: path)
    }

    @MainActor
    static func renderAssociations(to path: String) -> Bool {
        let view = AssociationsView()
            .background(Color(nsColor: .windowBackgroundColor))
        return renderHosted(view, width: 580, height: 540, path: path)
    }

    @MainActor
    private static func renderHosted<V: View>(
        _ view: V,
        width: CGFloat,
        height: CGFloat,
        path: String
    ) -> Bool {
        // ImageRenderer cannot draw AppKit-backed controls such as Pickers and
        // ProgressView, so host the view in an off-screen window and cache it.
        let active = view
            .environment(\.controlActiveState, .key)
        let hosting = NSHostingView(rootView: active)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()

        defer { window.orderOut(nil) }

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("Could not create bitmap")
            return false
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            print("Could not encode PNG")
            return false
        }

        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("Wrote \(path)")
            return true
        } catch {
            print("Could not write snapshot: \(error.localizedDescription)")
            return false
        }
    }
}
