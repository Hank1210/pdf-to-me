import AppKit
import PDFKit
import PDFToMeCore

/// Ein geöffnetes Dokument. Hält den `WorkingDocument` aus dem Core; die Logik liegt dort.
///
/// Schreibt nie in die geöffnete Datei (Rolle „Viewer“ in der Info.plist, `data(ofType:)` lehnt ab). Gespeichert wird
/// immer als neue Datei über die Speicher-Pipeline (Schritt 12).
@objc(PDFToMeDocument)
final class PDFToMeDocument: NSDocument {
    private(set) var working: WorkingDocument?

    override class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        working = try Self.open(url)
    }

    override func data(ofType typeName: String) throws -> Data {
        // Das Original wird nie überschrieben.
        throw CocoaError(.featureUnsupported)
    }

    override func makeWindowControllers() {
        guard let working else { return }
        addWindowController(DocumentWindowController(document: self, working: working))
    }

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

    override func close() {
        // Ohne ungespeicherte Änderungen wird keine Sicherung gebraucht. (Rückfrage bei Änderungen: Schritt 12.)
        working?.discardSession()
        super.close()
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
