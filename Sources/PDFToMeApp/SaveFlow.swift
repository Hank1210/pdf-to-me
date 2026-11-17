import AppKit
import PDFToMeCore

/// Speichern, Extrahieren und Teilen aus Sicht der Oberfläche: fragt, was nötig ist, und meldet das Ergebnis.
/// Geschrieben und geprüft wird im Core (`SavePipeline`, `Splitter`).
@MainActor
enum SaveFlow {
    /// Writer in M1a. Ab M1b `PDFiumWriter`.
    static var pipeline: SavePipeline { SavePipeline(writer: PDFKitWriter()) }

    // MARK: Speichern

    /// Speichert das ganze Dokument als neue Datei neben dem Original, z. B. `Vertrag (bearbeitet).pdf`.
    /// `true`, wenn gespeichert wurde.
    @discardableResult
    static func saveCopy(of document: PDFToMeDocument, window: NSWindow, reportResult: Bool = true) -> Bool {
        guard let working = document.working else { return false }
        let baseName = FileNaming.editedBaseName(forOriginal: working.displayName)
        guard let result = save(working.plan, contents: working.contents, folder: working.defaultFolder,
                                baseName: baseName, window: window)
        else { return false }
        document.updateChangeCount(.changeCleared)
        working.discardSession()
        if reportResult { report([result], window: window) }
        return true
    }

    /// Speichert die gewählten Seiten als neue Datei, z. B. `Vertrag (3–5).pdf`.
    static func extract(_ ids: [PageRef.ID], of working: WorkingDocument, window: NSWindow) {
        do {
            let plan = try working.plan.extracting(ids)
            let positions = ids.compactMap { working.plan.position(of: $0) }
            let baseName = Splitter.extractBaseName(stem: working.stem, positions: positions)
            if let result = save(plan, contents: working.contents, folder: working.defaultFolder,
                                 baseName: baseName, window: window) {
                report([result], window: window)
            }
        } catch {
            showError(error, window: window)
        }
    }

    /// Teilt das Dokument; jeder Teil wird einzeln gespeichert und das Ergebnis gesammelt gemeldet.
    static func split(_ working: WorkingDocument, into parts: [SplitPart], window: NSWindow) {
        guard let options = writeOptions(for: working.plan, window: window),
              let folder = folder(working.defaultFolder, window: window)
        else { return }
        let results = Splitter.save(working.plan, contents: working.contents, parts: parts, in: folder,
                                    stem: working.stem, pipeline: pipeline, options: options)
        var saved: [SaveResult] = []
        var failures: [String] = []
        for part in results {
            switch part.result {
            case let .success(result): saved.append(result)
            case let .failure(error):
                failures.append(loc("Seiten \(part.part.label): ", "Pages \(part.part.label): ")
                                + (error.localizedDescription))
            }
        }
        report(saved, failures: failures, window: window)
    }

    // MARK: Ablauf

    /// Fragt bei Bedarf nach dem Passwortschutz und dem Ordner, speichert und zeigt Fehler an. `nil` bei Abbruch
    /// oder Fehler.
    private static func save(_ plan: DocumentPlan, contents: SourceContents, folder: URL?, baseName: String,
                             window: NSWindow) -> SaveResult? {
        guard let options = writeOptions(for: plan, window: window),
              var folder = self.folder(folder, window: window)
        else { return nil }
        while true {
            do {
                return try pipeline.save(plan, contents: contents, in: folder, baseName: baseName, options: options)
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

    private static func report(_ saved: [SaveResult], failures: [String] = [], window: NSWindow) {
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

    static func showError(_ error: Error, window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc("Nicht gespeichert", "Not saved")
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }
}
