import AppKit
import PDFToMeCore

/// Aktionen der Dokumentfenster. Menüeinträge schicken sie an die Responder-Kette (Ziel `nil`);
/// `DocumentWindowController` setzt sie um.
@objc protocol DocumentActions {
    func focusSearch(_ sender: Any?)
    func showThumbnails(_ sender: Any?)
    func showOutline(_ sender: Any?)
    func resetZoom(_ sender: Any?)
    func zoomToFit(_ sender: Any?)
    func toggleTwoPages(_ sender: Any?)
}

/// Das Hauptmenü, im Code aufgebaut (die App hat keine Nib-Dateien). Alle Texte zweisprachig über `loc`.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: loc("Hilfe", "Help"))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    // MARK: Menüs

    private static func appMenu() -> NSMenu {
        let name = AppIdentity.name
        let menu = NSMenu(title: name)
        menu.addItem(item(loc("Über \(name)", "About \(name)"),
                          #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: loc("Dienste", "Services"))
        menu.addItem(submenu(services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item(loc("\(name) ausblenden", "Hide \(name)"), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(loc("Andere ausblenden", "Hide Others"),
                          #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item(loc("Alle einblenden", "Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(loc("\(name) beenden", "Quit \(name)"), #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: loc("Ablage", "File"))
        menu.addItem(item(loc("Öffnen …", "Open…"), #selector(NSDocumentController.openDocument(_:)), "o"))
        // AppKit erkennt das Menü „Zuletzt benutzt“ an dem Eintrag mit `clearRecentDocuments:` und füllt es selbst.
        let recent = NSMenu(title: loc("Zuletzt benutzt", "Open Recent"))
        recent.addItem(item(loc("Einträge löschen", "Clear Menu"),
                            #selector(NSDocumentController.clearRecentDocuments(_:))))
        menu.addItem(submenu(recent))
        menu.addItem(.separator())
        menu.addItem(item(loc("Schließen", "Close"), #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item(loc("Papierformat …", "Page Setup…"), #selector(NSDocument.runPageLayout(_:)), "p",
                          [.command, .shift]))
        menu.addItem(item(loc("Drucken …", "Print…"), #selector(NSDocument.printDocument(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: loc("Bearbeiten", "Edit"))
        menu.addItem(item(loc("Kopieren", "Copy"), #selector(NSText.copy(_:)), "c"))
        menu.addItem(item(loc("Alles auswählen", "Select All"), #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item(loc("Suchen …", "Find…"), #selector(DocumentActions.focusSearch(_:)), "f"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: loc("Darstellung", "View"))
        menu.addItem(item(loc("Miniaturen", "Thumbnails"), #selector(DocumentActions.showThumbnails(_:)), "1",
                          [.command, .option]))
        menu.addItem(item(loc("Inhaltsverzeichnis", "Table of Contents"),
                          #selector(DocumentActions.showOutline(_:)), "2", [.command, .option]))
        menu.addItem(item(loc("Seitenleiste ein-/ausblenden", "Toggle Sidebar"),
                          #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item(loc("Vergrößern", "Zoom In"), #selector(PDFViewZoom.zoomIn(_:)), "+"))
        menu.addItem(item(loc("Verkleinern", "Zoom Out"), #selector(PDFViewZoom.zoomOut(_:)), "-"))
        menu.addItem(item(loc("Originalgröße", "Actual Size"), #selector(DocumentActions.resetZoom(_:)), "0"))
        menu.addItem(item(loc("An Fenster anpassen", "Zoom to Fit"), #selector(DocumentActions.zoomToFit(_:)), "9"))
        menu.addItem(.separator())
        menu.addItem(item(loc("Zwei Seiten", "Two Pages"), #selector(DocumentActions.toggleTwoPages(_:))))
        menu.addItem(.separator())
        menu.addItem(item(loc("Vollbild", "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f",
                          [.command, .control]))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: loc("Gehe zu", "Go"))
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        menu.addItem(item(loc("Vorherige Seite", "Previous Page"), #selector(PDFViewZoom.goToPreviousPage(_:)),
                          up, [.command, .option]))
        menu.addItem(item(loc("Nächste Seite", "Next Page"), #selector(PDFViewZoom.goToNextPage(_:)),
                          down, [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item(loc("Erste Seite", "First Page"), #selector(PDFViewZoom.goToFirstPage(_:)),
                          up, [.command]))
        menu.addItem(item(loc("Letzte Seite", "Last Page"), #selector(PDFViewZoom.goToLastPage(_:)),
                          down, [.command]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: loc("Fenster", "Window"))
        menu.addItem(item(loc("Im Dock ablegen", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(loc("Zoomen", "Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(loc("Alle nach vorne bringen", "Bring All to Front"),
                          #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    // MARK: Hilfen

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Selektoren, die `PDFView` selbst umsetzt; `DocumentWindowController` leitet sie weiter, wenn der Fokus in der
/// Seitenleiste liegt.
@objc protocol PDFViewZoom {
    func zoomIn(_ sender: Any?)
    func zoomOut(_ sender: Any?)
    func goToPreviousPage(_ sender: Any?)
    func goToNextPage(_ sender: Any?)
    func goToFirstPage(_ sender: Any?)
    func goToLastPage(_ sender: Any?)
}
