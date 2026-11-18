import AppKit
import DocKit
import PDFKit
import PDFToMeCore

/// Ein geöffnetes Dokument. Hält den `WorkingDocument` aus dem Core; die Logik liegt dort.
///
/// Schreibt nie in die geöffnete Datei (Rolle „Viewer“ in der Info.plist, `data(ofType:)` lehnt ab, kein Autosave).
/// Gespeichert wird immer als neue Datei über die Speicher-Pipeline (`SaveFlow`).
///
/// Undo: Der Plan führt die eigentlichen Undo- und Redo-Stapel. Der `undoManager` des Dokuments bekommt je Schritt
/// nur einen Eintrag, der `working.undo()` oder `working.redo()` aufruft. So funktionieren Menü „Bearbeiten“,
/// die Markierung „bearbeitet“ und die Rückfrage beim Schließen wie gewohnt.
@objc(PDFToMeDocument)
final class PDFToMeDocument: NSDocument {
    private(set) var working: WorkingDocument?

    override class var autosavesInPlace: Bool { false }

    /// Ein wiederhergestellter Arbeitsstand nach einem Absturz.
    convenience init(restored working: WorkingDocument) {
        self.init()
        self.working = working
        fileURL = working.plan.sources.first.flatMap(SourceLoader.resolve)
        // Die gesicherten Schritte bleiben rückgängig machbar; ungespeichert ist der Stand ohnehin.
        for _ in working.plan.undoStack { registerUndoStep(loc("Änderung", "Change")) }
        updateChangeCount(.changeDone)
    }

    override var displayName: String! {
        get { working?.displayName ?? super.displayName }
        set { super.displayName = newValue }
    }

    override func read(from url: URL, ofType typeName: String) throws {
        working = try Self.open(url)
    }

    override func data(ofType typeName: String) throws -> Data {
        // Das Original wird nie überschrieben.
        throw CocoaError(.featureUnsupported)
    }

    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
                           completionHandler: @escaping (Error?) -> Void) {
        // Kein Autosave in die Datei; ungespeicherte Arbeit sichert die Sitzung (`SessionStore`).
        completionHandler(nil)
    }

    override func makeWindowControllers() {
        guard let working else { return }
        addWindowController(DocumentWindowController(document: self, working: working))
        StartWindow.shared.close()
    }

    // MARK: Änderungen und Undo

    /// Führt eine Änderung aus und legt dafür einen Undo-Schritt an. Fehler werden am Fenster angezeigt.
    func perform(_ actionName: String, _ body: (WorkingDocument) throws -> Void) {
        guard let working else { return }
        let steps = working.plan.undoStack.count
        do {
            try body(working)
        } catch {
            presentErrorSheet(error)
            return
        }
        if working.plan.undoStack.count > steps { registerUndoStep(actionName) }
    }

    private func registerUndoStep(_ name: String) {
        undoManager?.registerUndo(withTarget: self) { $0.step(name, undo: true) }
        undoManager?.setActionName(name)
    }

    private func step(_ name: String, undo: Bool) {
        do {
            if undo { try working?.undo() } else { try working?.redo() }
        } catch {
            // Plan und Undo-Manager laufen sonst auseinander; lieber den Verlauf im Menü verwerfen.
            undoManager?.removeAllActions()
            presentErrorSheet(error)
            return
        }
        undoManager?.registerUndo(withTarget: self) { $0.step(name, undo: !undo) }
        undoManager?.setActionName(name)
    }

    func presentErrorSheet(_ error: Error) {
        if let window = windowControllers.first?.window {
            presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
        } else {
            presentError(error)
        }
    }

    // MARK: Schließen

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        let answer: (Bool) -> Void = { [self] shouldClose in
            Self.callBack(delegate, shouldCloseSelector, document: self, shouldClose, contextInfo)
        }
        guard isDocumentEdited, let window = windowControllers.first?.window else {
            answer(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = loc("Möchten Sie Ihre Änderungen an „\(displayName ?? "")“ als neue Datei speichern?",
                                "Do you want to save your changes to “\(displayName ?? "")” as a new file?")
        alert.informativeText = loc("Ihr Original bleibt in jedem Fall unverändert.",
                                    "Your original stays unchanged in any case.")
        alert.addButton(withTitle: loc("Speichern …", "Save…"))
        alert.addButton(withTitle: loc("Abbrechen", "Cancel"))
        let discard = alert.addButton(withTitle: loc("Nicht speichern", "Don’t Save"))
        discard.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [self] response in
            switch response {
            case .alertFirstButtonReturn:
                // Das Fenster schließt gleich; keine Erfolgsmeldung daran hängen.
                answer(SaveFlow.saveCopy(of: self, window: window, reportResult: false))
            case .alertThirdButtonReturn:
                working?.discardSession()
                answer(true)
            default:
                answer(false)
            }
        }
    }

    override func close() {
        // Ohne ungespeicherte Änderungen wird keine Sicherung gebraucht.
        if !isDocumentEdited { working?.discardSession() }
        super.close()
    }

    /// Ruft den Delegate von `canClose` mit der Antwort auf (Signatur nach AppKit-Dokumentation).
    private static func callBack(_ delegate: Any, _ selector: Selector?, document: NSDocument, _ shouldClose: Bool,
                                 _ contextInfo: UnsafeMutableRawPointer?) {
        guard let selector, let object = delegate as? NSObject, object.responds(to: selector) else { return }
        typealias Callback = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        let function = unsafeBitCast(object.method(for: selector), to: Callback.self)
        function(object, selector, document, shouldClose, contextInfo)
    }

    // MARK: Drucken

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws
        -> NSPrintOperation {
        guard let document = working?.preview.document else { throw CocoaError(.featureUnsupported) }
        let info = printInfo.copy() as? NSPrintInfo ?? printInfo
        info.dictionary().addEntries(from: printSettings)
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true)
        else { throw CocoaError(.featureUnsupported) }
        operation.jobTitle = displayName
        // Seitenbereich, Kopien und Vorschau stehen im Druckdialog; „Ausgewählte Seiten“ ist ein Seitenbereich.
        operation.printPanel.options.formUnion([.showsPageRange, .showsCopies, .showsPreview, .showsOrientation,
                                                .showsScaling, .showsPaperSize])
        return operation
    }

    // MARK: Öffnen

    /// Öffnet eine Datei; ist sie geschützt, wird nach dem Passwort gefragt, bis es stimmt oder abgebrochen wird.
    private static func open(_ url: URL) throws -> WorkingDocument {
        let store = try? SessionStore.standard()
        do {
            return try WorkingDocument(opening: url, sessionStore: store)
        } catch let error as SourceLoadError where error.needsPassword {
            var wrongBefore = false
            while true {
                guard let password = PasswordPrompt.ask(fileName: url.lastPathComponent, wrongBefore: wrongBefore)
                else { throw CocoaError(.userCancelled) }
                do {
                    return try WorkingDocument(opening: url, password: password, sessionStore: store)
                } catch let error as SourceLoadError where error.needsPassword {
                    wrongBefore = true
                }
            }
        }
    }
}
