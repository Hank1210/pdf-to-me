import DocKit
import Foundation

/// Ein Problem mit einer Quelle beim Wiederherstellen. Gemeldet werden nur Quellen, die noch Seiten im Dokument
/// haben (Entscheidung vom 17.11.2026).
public enum SourceProblem: Equatable {
    /// Die Datei ist nicht mehr auffindbar. Lösung: Datei zurücklegen und erneut versuchen, oder ihre Seiten entfernen.
    case missing(SourceFile)
    /// Die Datei ist da, ihr Inhalt hat sich aber geändert. Ihre Seiten zeigen nicht mehr sicher auf denselben Inhalt.
    case changed(SourceFile)
    /// Die Datei ist geschützt; das Passwort wird nie gespeichert und muss erneut eingegeben werden.
    case needsPassword(SourceFile)
    /// Die Datei ist da, lässt sich aber nicht öffnen.
    case unreadable(SourceFile, SourceLoadError)

    public var source: SourceFile {
        switch self {
        case let .missing(source), let .changed(source), let .needsPassword(source), let .unreadable(source, _):
            source
        }
    }

    var logName: StaticString {
        switch self {
        case .missing: "missing"
        case .changed: "changed"
        case .needsPassword: "needsPassword"
        case .unreadable: "unreadable"
        }
    }

    public var message: String {
        let name = source.displayName
        switch self {
        case .missing:
            return loc("„\(name)“ wurde verschoben, umbenannt oder gelöscht, solange Ihre Arbeit ungespeichert war. "
                       + "Legen Sie die Datei zurück oder entfernen Sie ihre Seiten aus dem Dokument.",
                       "“\(name)” was moved, renamed or deleted while your work was unsaved. Put it back or remove "
                       + "its pages from the document.")
        case .changed:
            return loc("„\(name)“ wurde verändert, solange Ihre Arbeit ungespeichert war. Ihre Seiten zeigen "
                       + "möglicherweise nicht mehr denselben Inhalt.",
                       "“\(name)” was changed while your work was unsaved. Its pages may no longer show the same "
                       + "content.")
        case .needsPassword:
            return loc("„\(name)“ ist mit einem Passwort geschützt. Bitte geben Sie es erneut ein.",
                       "“\(name)” is protected by a password. Please enter it again.")
        case let .unreadable(_, error):
            return error.errorDescription ?? loc("„\(name)“ lässt sich nicht öffnen.", "“\(name)” cannot be opened.")
        }
    }
}

/// Ein wiederhergestellter Arbeitsstand: der Plan, die geöffneten Quellen und offene Probleme.
///
/// Solange `problems` nicht leer ist, lässt sich der Plan nicht zusammensetzen. Die App zeigt jedes Problem an und
/// löst es mit `providePassword`, `retry` oder `removePages(from:)`.
public struct RestoredSession {
    public private(set) var plan: DocumentPlan
    public private(set) var contents: SourceContents
    public private(set) var problems: [SourceProblem]

    public var isComplete: Bool { problems.isEmpty }

    /// Öffnet die Quellen eines gesicherten Plans erneut und prüft, ob sie fehlen oder sich geändert haben.
    public init(_ plan: DocumentPlan) {
        self.plan = plan
        self.contents = [:]
        self.problems = []
        retry()
    }

    /// Versucht alle Quellen mit Problemen erneut zu öffnen, z. B. nachdem der Nutzer eine Datei zurückgelegt hat.
    public mutating func retry() {
        problems = []
        for source in plan.sourcesInUse where contents[source.id] == nil {
            open(source, password: source.password)
        }
        Log.shared.info("session restored", [
            "plan": .id(plan.id), "sources": .int(plan.sourcesInUse.count), "problems": .int(problems.count),
        ])
        for problem in problems {
            Log.shared.warning("source problem", ["source": .id(problem.source.id), "problem": .name(problem.logName)])
        }
    }

    /// Öffnet eine geschützte Quelle mit dem eingegebenen Passwort. Wirft bei falschem Passwort; das Problem bleibt.
    public mutating func providePassword(_ password: String, for id: SourceFile.ID) throws {
        guard let source = plan.source(withID: id) else { throw DocumentPlanError.unknownSourceID(id) }
        let loaded = try SourceLoader.reopen(source, password: password)
        try plan.setPassword(loaded.source.password, for: id)
        contents[id] = loaded.content
        problems.removeAll { $0.source.id == id }
    }

    /// Entfernt alle Seiten einer Quelle aus dem Dokument (rückgängig machbar) und damit ihr Problem.
    public mutating func removePages(from id: SourceFile.ID) throws {
        try plan.remove(plan.pageIDs(from: id))
        problems.removeAll { $0.source.id == id }
    }

    private mutating func open(_ source: SourceFile, password: String?) {
        guard let location = SourceLoader.locate(source) else {
            problems.append(.missing(source))
            return
        }
        if let refreshed = location.refreshedBookmark {
            try? plan.replaceBookmark(refreshed, for: source.id)
        }
        let current = plan.source(withID: source.id) ?? source
        do {
            let loaded = try SourceLoader.reopen(current, password: password)
            contents[source.id] = loaded.content
        } catch let error as SourceLoadError {
            switch error {
            case .changedSinceOpened: problems.append(.changed(current))
            case .missing: problems.append(.missing(current))
            case .passwordRequired, .wrongPassword: problems.append(.needsPassword(current))
            default: problems.append(.unreadable(current, error))
            }
        } catch {
            problems.append(.unreadable(current, .unreadable(fileName: source.displayName, reason: "\(error)")))
        }
    }
}
