import MnemeAppSupport
import AppKit
import SwiftUI

@main
enum MnemeMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            exit(SmokeTest.run() ? 0 : 1)
        }
        Mneme.main()
    }
}

/// Named apart from the module (MnemeApp) so qualified names stay unambiguous.
struct Mneme: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Mneme", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.recorder)
                .environmentObject(model.player)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    await model.start()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording") {
                    model.route = .recorder
                }
                .keyboardShortcut("r")
                Button("New Note") {
                    model.route = .newNote
                }
                .keyboardShortcut("n")
                Divider()
                Button("Import Recordings…") {
                    model.isImportingFiles = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu("Archive") {
                Button("Review Flagged Passages") {
                    model.route = .review
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Verify Archive") {
                    Task {
                        await model.verifyArchive()
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary runs outside an app bundle (swift run); harmless inside Mneme.app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
