import AppKit
import PDFToMeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // Erst ungesicherte Arbeit anbieten; ohne geöffnetes Dokument dann den Öffnen-Dialog zeigen, wie Vorschau.
        // Später, damit Dokumente aus dem Finder oder aus der Fensterwiederherstellung zuerst ankommen.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let restored = SessionRecovery.offerAtLaunch()
                if !restored, NSDocumentController.shared.documents.isEmpty {
                    NSDocumentController.shared.openDocument(nil)
                }
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
