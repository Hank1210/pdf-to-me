import AppKit
import PDFToMeCore

// Klassischer AppKit-Ablauf statt SwiftUI-`App`: Dokumente laufen über NSDocument und NSDocumentController
// (Fenster-Tabs, „Zuletzt benutzt“, Öffnen aus dem Finder). Die Ansichten im Fenster sind teils SwiftUI.

Localization.current = AppLanguage.systemDefault()
Log.shared.configure(file: try? AppIdentity.logFile())
Log.shared.info("app started")

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.mainMenu = MainMenu.make()
application.run()
