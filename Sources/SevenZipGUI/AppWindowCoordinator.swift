import AppKit
import SwiftUI

/// Keeps track of the SwiftUI window so a Finder service (or a Dock click) can
/// bring it back when the app is running with no visible windows.
@MainActor
final class AppWindowCoordinator {
    static let shared = AppWindowCoordinator()

    var openWindow: (() -> Void)?
    weak var mainWindow: NSWindow?

    func present() {
        NSApp.unhide(nil)

        // Pick the main archive window by identity. Auxiliary windows such as
        // About and 7-Zip Engine can also become main; without this check a
        // Finder action could surface one of them instead of the archive UI.
        let mainIdentifier = NSUserInterfaceItemIdentifier("Finder7MainWindow")
        if mainWindow == nil {
            mainWindow = NSApp.windows.first {
                $0.identifier == mainIdentifier || $0.title == "Finder7"
            }
        }

        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?()
        }

        NSApp.activate()
    }

    /// The window may not exist yet during a cold service launch. Try once
    /// immediately and once after SwiftUI has had a chance to create it.
    func presentWhenReady() {
        present()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            present()
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier("Finder7MainWindow")
            AppWindowCoordinator.shared.mainWindow = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                window.identifier = NSUserInterfaceItemIdentifier("Finder7MainWindow")
                AppWindowCoordinator.shared.mainWindow = window
            }
        }
    }
}

/// Captures SwiftUI's openWindow action so the coordinator can recreate the
/// main window after the user closes it.
struct WindowOpenBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppWindowCoordinator.shared.openWindow = {
                    openWindow(id: "main")
                }
            }
    }
}
