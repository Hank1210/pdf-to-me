import Foundation
import PDFKit

/// Der Arbeitsstand eines Fensters: Plan, geöffnete Quellen und die Vorschau.
///
/// Jede Änderung läuft über `change`: Der Plan wird geändert, die Vorschau neu zusammengesetzt und die Sitzung
/// gesichert. Schlägt etwas fehl, bleibt alles beim alten Stand. Die Oberfläche hört auf `onChange`.
public final class WorkingDocument {
    public private(set) var plan: DocumentPlan
    public private(set) var contents: SourceContents
    public private(set) var preview: AssembledDocument
    public let sessionStore: SessionStore?

    /// Wird nach jeder übernommenen Änderung aufgerufen.
    public var onChange: (() -> Void)?

    /// Öffnet eine Datei als neues Dokument. Wirft `SourceLoadError`, z. B. wenn ein Passwort nötig ist.
    public convenience init(opening url: URL, password: String? = nil, sessionStore: SessionStore?) throws {
        let loaded = try SourceLoader.load(url, password: password)
        try self.init(
            plan: DocumentPlan(source: loaded.source), contents: [loaded.source.id: loaded.content],
            sessionStore: sessionStore)
    }

    /// Übernimmt einen wiederhergestellten Arbeitsstand. Er muss vollständig sein (`isComplete`).
    public convenience init(restored session: RestoredSession, sessionStore: SessionStore?) throws {
        try self.init(plan: session.plan, contents: session.contents, sessionStore: sessionStore)
    }

    init(plan: DocumentPlan, contents: SourceContents, sessionStore: SessionStore?) throws {
        self.plan = plan
        self.contents = contents
        self.preview = try PlanAssembler.assemble(plan, contents: contents)
        self.sessionStore = sessionStore
    }

    /// Name für Fenster und Meldungen: der Name der ersten Quelle.
    public var displayName: String {
        plan.sources.first?.displayName ?? AppIdentity.name
    }

    /// Ändert den Plan. Ändert sich nichts, geschieht nichts; bei einem Fehler bleibt alles unverändert.
    public func change(_ body: (inout DocumentPlan) throws -> Void) throws {
        var candidate = plan
        try body(&candidate)
        guard candidate != plan else { return }
        try commit(plan: candidate, contents: contents)
    }

    /// Fügt geladene Quellen hinzu (Zusammenführen, Bilder einfügen) und ändert dabei den Plan.
    public func add(_ loaded: [LoadedSource], change body: (inout DocumentPlan) throws -> Void) throws {
        var newContents = contents
        for source in loaded { newContents[source.source.id] = source.content }
        var candidate = plan
        try body(&candidate)
        try commit(plan: candidate, contents: newContents)
    }

    /// Fügt geladene Dateien mit allen Seiten an `position` ein, als ein einziger Undo-Schritt.
    public func insertFiles(_ loaded: [LoadedSource], at position: Int) throws {
        guard !loaded.isEmpty else { return }
        let pages = loaded.flatMap { file in
            (0..<file.source.pageCount).map { PageRef(source: file.source.id, index: $0) }
        }
        try add(loaded) { try $0.insert(pages, at: position, addingSources: loaded.map(\.source)) }
    }

    /// Der Ordner, in dem neue Dateien landen: der Ordner der ersten Quelle (README: „next to the original“).
    public var defaultFolder: URL? {
        plan.sources.first.flatMap(SourceLoader.resolve)?.deletingLastPathComponent()
    }

    /// Name ohne Endung für die erste Quelle, ohne Kennzeichnung als bearbeitet; Grundlage aller Zielnamen.
    public var stem: String {
        FileNaming.stem(of: displayName)
    }

    public func undo() throws { try change { try $0.undo() } }
    public func redo() throws { try change { try $0.redo() } }

    /// Entfernt die Sitzungssicherung, z. B. wenn das Fenster ohne ungespeicherte Änderungen geschlossen wird.
    public func discardSession() {
        try? sessionStore?.remove(plan.id)
    }

    private func commit(plan newPlan: DocumentPlan, contents newContents: SourceContents) throws {
        let newPreview = try PlanAssembler.assemble(newPlan, contents: newContents)
        plan = newPlan
        contents = newContents
        preview = newPreview
        do {
            try sessionStore?.save(plan)
        } catch {
            Log.shared.error("session not saved", ["plan": .id(plan.id), "error": .error(error)])
        }
        onChange?()
    }
}
