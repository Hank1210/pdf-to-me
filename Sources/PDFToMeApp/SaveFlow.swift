import AppKit
import DocKit
import PDFToMeCore

/// Speichern, Extrahieren und Teilen aus Sicht der Oberfläche: fragt, was nötig ist, und meldet das Ergebnis.
/// Geschrieben und geprüft wird im Core (`SavePipeline`, `Splitter`).
@MainActor
enum SaveFlow {
    /// Writer ab M1b: qpdf, strukturerhaltend (Links, Inhaltsverzeichnis, Formularfelder).
    static var pipeline: SavePipeline { SavePipeline(writer: QPDFKitWriter()) }

    // MARK: Speichern

    /// Speichert das ganze Dokument als neue Datei neben dem Original, z. B. `Vertrag (bearbeitet).pdf`.
    /// Mit `reduceImages` werden die Bilder verkleinert (`Vertrag (verkleinert).pdf`), und die Meldung nennt die
    /// Größe ohne und mit Verkleinerung. `true`, wenn gespeichert wurde.
    @discardableResult
    static func saveCopy(of document: PDFToMeDocument, window: NSWindow, reportResult: Bool = true,
                         reduceImages: Bool = false) -> Bool {
        guard let working = document.working else { return false }
        let baseName = reduceImages ? FileNaming.reducedBaseName(forOriginal: working.displayName)
                                    : FileNaming.editedBaseName(forOriginal: working.displayName)
        guard let (result, sizes) = save(working.plan, contents: working.contents, folder: working.defaultFolder,
                                         baseName: baseName, textLayers: working.recognitionCache,
                                         reduceImages: reduceImages, window: window)
        else { return false }
        document.updateChangeCount(.changeCleared)
        working.discardSession()
        if reportResult { report([result], sizes: sizes, window: window) }
        return true
    }

    /// Speichert die gewählten Seiten als neue Datei, z. B. `Vertrag (3–5).pdf`.
    static func extract(_ ids: [PageRef.ID], of working: WorkingDocument, window: NSWindow) {
        do {
            let plan = try working.plan.extracting(ids)
            let positions = ids.compactMap { working.plan.position(of: $0) }
            let baseName = Splitter.extractBaseName(stem: working.stem, positions: positions)
            if let (result, _) = save(plan, contents: working.contents, folder: working.defaultFolder,
                                      baseName: baseName, textLayers: working.recognitionCache, window: window) {
                report([result], window: window)
            }
        } catch {
            showError(error, window: window)
        }
    }

    /// Teilt das Dokument; jeder Teil wird einzeln gespeichert und das Ergebnis gesammelt gemeldet.
    static func split(_ working: WorkingDocument, into parts: [SplitPart], window: NSWindow) {
        guard var options = writeOptions(for: working.plan, window: window),
              let folder = folder(working.defaultFolder, window: window)
        else { return }
        options.textLayers = working.recognitionCache
        let results = Splitter.save(working.plan, contents: working.contents, parts: parts, in: folder,
                                    stem: working.stem, pipeline: pipeline, options: options)
        var saved: [SaveResult] = []
        var failures: [String] = []
        for part in results {
            switch part.result {
            case let .success(result): saved.append(result)
            case let .failure(error):
                let single = part.part.first == part.part.last
                let label = single ? loc("Seite \(part.part.label): ", "Page \(part.part.label): ")
                                   : loc("Seiten \(part.part.label): ", "Pages \(part.part.label): ")
                failures.append(label + reason(error))
            }
        }
        report(saved, failures: failures, window: window)
    }

    // MARK: Ablauf

    /// Fragt bei Bedarf nach dem Passwortschutz und dem Ordner, speichert und zeigt Fehler an. `nil` bei Abbruch
    /// oder Fehler. Mit `reduceImages` kommt der Größenvergleich mit; fehlt er, war die Vergleichsdatei nicht zu
    /// schreiben, gespeichert ist trotzdem.
    private static func save(_ plan: DocumentPlan, contents: SourceContents, folder: URL?, baseName: String,
                             textLayers: TextRecognitionCache, reduceImages: Bool = false,
                             window: NSWindow) -> (SaveResult, SizeComparison?)? {
        guard var options = writeOptions(for: plan, window: window),
              var folder = self.folder(folder, window: window)
        else { return nil }
        options.textLayers = textLayers
        options.reduceImages = reduceImages
        while true {
            do {
                let result = try pipeline.save(plan, contents: contents, in: folder, baseName: baseName,
                                               options: options)
                guard reduceImages else { return (result, nil) }
                return (result, pipeline.sizeComparison(plan, contents: contents, saved: result.url,
                                                        options: options))
            } catch SaveError.cannotWrite {
                // Ordner nicht beschreibbar: einen anderen wählen lassen.
                guard let other = chooseFolder(
                    message: loc("Im Ordner „\(folder.lastPathComponent)“ lässt sich nicht speichern. Wählen Sie "
                                 + "einen anderen Ordner.",
                                 "Cannot save in the folder “\(folder.lastPathComponent)”. Choose another folder."))
                else { return nil }
                folder = other
            } catch {
                showError(error, window: window)
                return nil
            }
        }
    }

    private static func folder(_ preferred: URL?, window: NSWindow) -> URL? {
        if let preferred { return preferred }
        return chooseFolder(message: loc("Der Ordner des Originals ist nicht mehr auffindbar. Wo soll gespeichert "
                                         + "werden?",
                                         "The original’s folder can no longer be found. Where should the file be "
                                         + "saved?"))
    }

    private static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = loc("Hier speichern", "Save Here")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Variante 3: Stammen Seiten aus einer geschützten Quelle, wird gefragt; vorbelegt mit „Ja“ und dem Passwort.
    /// `nil` bei Abbruch.
    static func writeOptions(for plan: DocumentPlan, window: NSWindow) -> WriteOptions? {
        guard let suggestion = ProtectionSuggestion(for: plan) else { return WriteOptions() }
        var emptyBefore = false
        while true {
            let alert = NSAlert()
            alert.messageText = loc("Mit Passwort schützen?", "Protect with a password?")
            let names = suggestion.protectedSourceNames.map { "„\($0)“" }.joined(separator: ", ")
            let namesEN = suggestion.protectedSourceNames.map { "“\($0)”" }.joined(separator: ", ")
            alert.informativeText = loc(
                "Seiten stammen aus der geschützten Datei \(names). Ohne Passwort kann jeder die neue Datei öffnen.",
                "Pages come from the protected file \(namesEN). Without a password, anyone can open the new file.")
                + (emptyBefore ? "\n\n" + loc("Bitte geben Sie ein Passwort ein.", "Please enter a password.") : "")
            let protect = NSButton(checkboxWithTitle: loc("Mit Passwort schützen", "Protect with password"),
                                   target: nil, action: nil)
            protect.state = .on
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = suggestion.password
            let stack = NSStackView(views: [protect, field])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
            alert.accessoryView = stack
            alert.addButton(withTitle: loc("Weiter", "Continue"))
            alert.addButton(withTitle: loc("Abbrechen", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if protect.state == .off { return WriteOptions() }
            if !field.stringValue.isEmpty { return WriteOptions(password: field.stringValue) }
            emptyBefore = true
        }
    }

    // MARK: Meldungen

    private static func report(_ saved: [SaveResult], failures: [String] = [], sizes: SizeComparison? = nil,
                               window: NSWindow) {
        let alert = NSAlert()
        let names = saved.map { "„\($0.url.lastPathComponent)“" }
        let namesEN = saved.map { "“\($0.url.lastPathComponent)”" }
        switch (saved.count, failures.isEmpty) {
        case (0, _):
            alert.alertStyle = .warning
            alert.messageText = loc("Es wurde keine Datei gespeichert.", "No file was saved.")
        case (1, true):
            alert.messageText = loc("Gespeichert als \(names[0]).", "Saved as \(namesEN[0]).")
        default:
            alert.messageText = loc("\(saved.count) Dateien gespeichert.", "\(saved.count) files saved.")
        }
        var details: [String] = []
        if let sizes { details.append(sizes.message) }
        if saved.count > 1 { details.append(names.joined(separator: "\n")) }
        if !failures.isEmpty {
            alert.alertStyle = .warning
            details.append(loc("Nicht gespeichert:", "Not saved:") + "\n" + failures.joined(separator: "\n"))
        }
        let warnings = saved.flatMap(\.warnings).map(\.message)
        if !warnings.isEmpty { details.append(warnings.joined(separator: "\n")) }
        details.append(loc("Ihr Original ist unverändert.", "Your original is unchanged."))
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: loc("OK", "OK"))
        if !saved.isEmpty { alert.addButton(withTitle: loc("Im Finder zeigen", "Show in Finder")) }
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting(saved.map(\.url))
            }
        }
    }

    /// Nur die Ursache, ohne den Satz zum Original; den hängt die Sammelmeldung einmal an.
    private static func reason(_ error: Error) -> String {
        if case let .verificationFailed(failures, _)? = error as? SaveError {
            return failures.map(\.message).joined(separator: " ")
        }
        return error.localizedDescription
    }

    static func showError(_ error: Error, window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc("Nicht gespeichert", "Not saved")
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }
}
