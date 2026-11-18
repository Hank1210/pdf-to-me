import AppKit
import PDFToMeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // Erst ungesicherte Arbeit anbieten; ohne geöffnetes Dokument dann das Startfenster zeigen.
        // Später, damit Dokumente aus dem Finder oder aus der Fensterwiederherstellung zuerst ankommen.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let restored = SessionRecovery.offerAtLaunch()
                if !restored { StartWindow.shared.showIfNoDocuments() }
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { StartWindow.shared.showIfNoDocuments() } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
