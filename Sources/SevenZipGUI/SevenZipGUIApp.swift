import AppKit
import SwiftUI

@main
struct SevenZipGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ArchiveModel.shared

    init() {
        // Headless metadata output used by the build and integration checks.
        if CommandLine.arguments.contains("--dependency-versions") {
            exit(SelfUpdateCLI.printDependencyVersions())
        }

        // Headless self-update checks and applies. No UI is created.
        if CommandLine.arguments.contains("--self-update") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let arguments = CommandLine.arguments
            Task.detached {
                exit(await SelfUpdateCLI.run(arguments: arguments))
            }
            dispatchMain()
        }

        // Headless self-check used by Scripts/build-app.sh and CI. Runs before any UI exists.
        if CommandLine.arguments.contains("--smoke-test") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task.detached {
                let passed = await SmokeTest.run()
                exit(passed ? 0 : 1)
            }
            dispatchMain()
        }

        // Off-screen render used for README screenshots and layout checks.
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot") {
            NSApplication.shared.setActivationPolicy(.accessory)
            if CommandLine.arguments.contains("--light") {
                NSApp.appearance = NSAppearance(named: .aqua)
            } else if CommandLine.arguments.contains("--dark") {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }

            let path = CommandLine.arguments.indices.contains(flag + 1)
                ? CommandLine.arguments[flag + 1]
                : "preview.png"
            let isSettings = CommandLine.arguments.contains("--settings")
            let isAssociations = CommandLine.arguments.contains("--associations")
            let isAbout = CommandLine.arguments.contains("--about")
            let isUpdate = CommandLine.arguments.contains("--update")
            let isFinished = CommandLine.arguments.contains("--finished")
            let isEmpty = CommandLine.arguments.contains("--empty")
            let mode: ArchiveModel.Mode = CommandLine.arguments.contains("--extract") ? .extract : .compress
            let tabName = Self.argumentValue(after: "--tab") ?? SettingsView.Tab.general.rawValue
            let tab = SettingsView.Tab(rawValue: tabName) ?? .general

            MainActor.assumeIsolated {
                if isAbout {
                    exit(Snapshot.renderAbout(to: path) ? 0 : 1)
                }
                if isUpdate {
                    exit(Snapshot.renderUpdate(to: path) ? 0 : 1)
                }
                if isAssociations {
                    exit(Snapshot.renderAssociations(to: path) ? 0 : 1)
                }
                if isSettings {
                    exit(Snapshot.renderSettings(to: path, tab: tab) ? 0 : 1)
                }
                exit(Snapshot.render(to: path, mode: mode, finished: isFinished, empty: isEmpty) ? 0 : 1)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Finder7", id: "main") {
            ContentView()
                .environmentObject(model)
                .background(WindowAccessor().frame(width: 0, height: 0))
                .background(WindowOpenBridge())
        }
        .defaultSize(width: 920, height: 660)
        .commands {
            Finder7Commands(model: model)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }

    private static func argumentValue(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else {
            return nil
        }
        return CommandLine.arguments[index + 1]
    }
}

/// Menu commands for the main app. Kept out of the App type so the shared
/// archive model is observed rather than captured once.
struct Finder7Commands: Commands {
    @ObservedObject var model: ArchiveModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Finder7") {
                AboutWindowController.shared.show()
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                EngineUpdateController.shared.checkForUpdates(force: true, present: true)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("Open Archive…") {
                model.setMode(.extract)
                model.chooseArchive()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(model.isRunning)

            Button("Add Files…") {
                model.setMode(.compress)
                model.chooseSources()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(model.isRunning)

            Divider()

            Button("Show Log") {
                model.showLog = true
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(model.logText.isEmpty)
        }

        CommandGroup(replacing: .help) {
            Button("7-Zip Website") {
                open("https://www.7-zip.org")
            }
            Button("Made by wychoi") {
                open("https://wychoi.com")
            }
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
