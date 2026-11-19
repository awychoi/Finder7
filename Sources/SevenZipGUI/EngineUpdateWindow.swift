import AppKit
import SwiftUI

/// The engine update is its own small window, so opening it from Settings,
/// the app menu, or the header never yanks the main window forward.
@MainActor
final class EngineUpdateWindowController {
    static let shared = EngineUpdateWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let root = ScrollView {
                EngineUpdateView(onClose: { [weak self] in
                    self?.window?.close()
                })
                .frame(minHeight: 300)
            }
            .frame(width: 520)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "7-Zip Engine"
            window.identifier = NSUserInterfaceItemIdentifier("Finder7EngineWindow")
            window.isReleasedWhenClosed = false
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 520, height: 300))
            window.center()
            self.window = window
        }

        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
