import AppKit
import SwiftUI

/// The app-menu About window. A plain NSWindow keeps the menu command reliable
/// and means the About panel is the same view used by Settings → About.
@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "About Finder7"
            window.identifier = NSUserInterfaceItemIdentifier("Finder7AboutWindow")
            window.isReleasedWhenClosed = false
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 540, height: 520))
            window.center()
            self.window = window
        }

        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
