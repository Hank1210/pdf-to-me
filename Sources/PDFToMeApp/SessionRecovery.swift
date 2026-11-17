import AppKit
import PDFToMeCore

/// Bietet beim Start an, ungesicherte Arbeit nach einem Absturz wiederherzustellen (README: „Unsaved work survives
/// a crash“). Die Logik liegt im Core (`SessionStore`, `RestoredSession`); hier wird gefragt und angezeigt.
@MainActor
enum SessionRecovery {
    /// `true`, wenn mindestens ein Dokument wiederhergestellt wurde.
    static func offerAtLaunch() -> Bool {
        guard let store = try? SessionStore.standard(), let stored = try? store.loadAll() else { return false }
        handleDamaged(stored.damaged)
        guard !stored.sessions.isEmpty else { return false }

        let names = stored.sessions.map { $0.sources.first?.displayName ?? AppIdentity.name }
        let alert = NSAlert()
        alert.messageText = loc("Ungesicherte Arbeit wiederherstellen?", "Restore unsaved work?")
        alert.informativeText = loc(
            "PDF to me wurde beendet, bevor diese Änderungen gesichert waren:",
            "PDF to me quit before these changes were saved:")
            + "\n\n" + names.map { "• \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: loc("Wiederherstellen", "Restore"))
        alert.addButton(withTitle: loc("Nicht jetzt", "Not Now"))
        let discard = alert.addButton(withTitle: loc("Verwerfen", "Discard"))
        discard.hasDestructiveAction = true

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return stored.sessions.reduce(false) { restore($1, store: store) || $0 }
        case .alertThirdButtonReturn:
            for plan in stored.sessions { try? store.remove(plan.id) }
            return false
        default:
            return false
        }
    }

    // MARK: Ein Arbeitsstand

    private static func restore(_ plan: DocumentPlan, store: SessionStore) -> Bool {
        var session = RestoredSession(plan)
        while let problem = session.problems.first {
            switch resolve(problem, in: &session) {
            case .continue: continue
            case .discard:
                try? store.remove(plan.id)
                return false
            }
        }
        do {
            let working = try WorkingDocument(restored: session, sessionStore: store)
            try? store.save(working.plan)
            let document = PDFToMeDocument(restored: working)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    private enum Outcome { case `continue`, discard }

    /// Zeigt ein Problem an und löst es nach Wahl des Nutzers.
    private static func resolve(_ problem: SourceProblem, in session: inout RestoredSession) -> Outcome {
        let source = problem.source
        if case .needsPassword = problem {
            var wrongBefore = false
            while let password = PasswordPrompt.ask(fileName: source.displayName, wrongBefore: wrongBefore) {
                do {
                    try session.providePassword(password, for: source.id)
                    return .continue
                } catch {
                    wrongBefore = true
                }
            }
            // Abgebrochen: Seiten entfernen oder verwerfen.
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc("Problem mit „\(source.displayName)“", "Problem with “\(source.displayName)”")
        alert.informativeText = problem.message
        let canRetry: Bool
        if case .missing = problem { canRetry = true } else { canRetry = false }
        if canRetry { alert.addButton(withTitle: loc("Erneut versuchen", "Try Again")) }
        alert.addButton(withTitle: loc("Seiten entfernen", "Remove Pages"))
        let discard = alert.addButton(withTitle: loc("Arbeitsstand verwerfen", "Discard Work"))
        discard.hasDestructiveAction = true

        let response = alert.runModal()
        let buttonIndex = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        switch (canRetry, buttonIndex) {
        case (true, 0):
            session.retry()
            return .continue
        case (true, 1), (false, 0):
            do {
                try session.removePages(from: source.id)
                return .continue
            } catch {
                return .discard
            }
        default:
            return .discard
        }
    }

    // MARK: Beschädigte Sicherungen

    private static func handleDamaged(_ files: [URL]) {
        guard !files.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc("Gesicherte Arbeit ist beschädigt", "Saved work is damaged")
        alert.informativeText = loc(
            "\(files.count) gesicherte Arbeitsstände lassen sich nicht lesen und nicht wiederherstellen. "
            + "Ihre Originaldateien sind davon nicht betroffen.",
            "\(files.count) saved work states cannot be read or restored. Your original files are not affected.")
        alert.addButton(withTitle: loc("Löschen", "Delete"))
        alert.addButton(withTitle: loc("Behalten", "Keep"))
        if alert.runModal() == .alertFirstButtonReturn {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }
}
