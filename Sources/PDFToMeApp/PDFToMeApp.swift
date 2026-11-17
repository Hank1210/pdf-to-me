import AppKit
import PDFToMeCore
import SwiftUI

@main
struct PDFToMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Localization.current = AppLanguage.systemDefault()
    }

    var body: some Scene {
        Window(AppIdentity.name, id: "main") {
            WelcomeView()
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Platzhalter, bis in M1a das Dokumentfenster kommt.
struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text(AppIdentity.name)
                .font(.largeTitle.bold())
            Text(AppIdentity.claim)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(loc("Grundgerüst – noch ohne Funktionen.", "Skeleton – no features yet."))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .frame(minWidth: 480, minHeight: 320)
    }
}
