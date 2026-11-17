import Foundation

/// Der Arbeitsstand eines Fensters: Quellen, die Liste der Ergebnisseiten und die Undo- und Redo-Stapel.
///
/// Der Plan ist immer in sich stimmig (siehe `validate`). Das gilt auch beim Dekodieren einer Sitzungsdatei:
/// Eine beschädigte Datei wird abgelehnt statt halb übernommen. Jede Änderung läuft über eine `PlanOperation` und
/// wird nur übernommen, wenn das Ergebnis stimmig ist; sonst bleibt der Plan unverändert. Erst beim Speichern
/// entsteht aus dem Plan eine PDF.
///
/// Quellen werden durch `remove` nicht entfernt, auch wenn keine ihrer Seiten mehr im Plan steht. Nur das
/// Rückgängigmachen eines Einfügens nimmt die dabei hinzugekommenen Quellen wieder heraus.
public struct DocumentPlan: Identifiable, Hashable, Sendable {
    /// Kennung des Arbeitsstands, zugleich Name der Sitzungsdatei `Sessions/<id>.json`.
    public let id: UUID
    public private(set) var sources: [SourceFile]
    public private(set) var pages: [PageRef]
    /// Ausgeführte Operationen, die letzte zuoberst.
    public private(set) var undoStack: [PlanOperation] = []
    /// Rückgängig gemachte Operationen, die letzte zuoberst. Wird bei jeder neuen Operation geleert.
    public private(set) var redoStack: [PlanOperation] = []

    public init(id: UUID = UUID(), sources: [SourceFile], pages: [PageRef]) throws {
        self.id = id
        self.sources = sources
        self.pages = pages
        try validate()
    }

    /// Ein Plan, der alle Seiten einer Quelle in ihrer Reihenfolge enthält, wie nach dem Öffnen einer Datei.
    public init(id: UUID = UUID(), source: SourceFile) throws {
        let pages = (0..<max(source.pageCount, 0)).map { PageRef(source: source.id, index: $0) }
        try self.init(id: id, sources: [source], pages: pages)
    }

    // MARK: Abfragen

    public func source(withID id: SourceFile.ID) -> SourceFile? {
        sources.first { $0.id == id }
    }

    /// Die Quelle, aus der eine Seite stammt. In einem gültigen Plan gibt es sie immer.
    public func source(of page: PageRef) -> SourceFile? {
        source(withID: page.source)
    }

    public func page(withID id: PageRef.ID) -> PageRef? {
        pages.first { $0.id == id }
    }

    /// Position einer Seite im Ergebnis, ab 0.
    public func position(of id: PageRef.ID) -> Int? {
        pages.firstIndex { $0.id == id }
    }

    /// Kennungen der Seiten aus einer Quelle, in der Reihenfolge des Plans.
    public func pageIDs(from source: SourceFile.ID) -> [PageRef.ID] {
        pages.filter { $0.source == source }.map(\.id)
    }

    /// Quellen, aus denen mindestens eine Seite im Plan steht, in der Reihenfolge von `sources`.
    public var sourcesInUse: [SourceFile] {
        let used = Set(pages.map(\.source))
        return sources.filter { used.contains($0.id) }
    }

    // MARK: Angaben zu Quellen (ohne Undo)

    // Diese Änderungen betreffen nicht den Inhalt des Dokuments und erzeugen deshalb keinen Undo-Schritt.

    /// Setzt das Passwort einer Quelle im Speicher, z. B. nach erneuter Abfrage beim Wiederherstellen.
    public mutating func setPassword(_ password: String?, for id: SourceFile.ID) throws {
        try updateSource(id) { $0.password = password }
    }

    /// Ersetzt ein veraltetes Bookmark durch ein neues, das auf dieselbe Datei zeigt.
    public mutating func replaceBookmark(_ bookmark: Data, for id: SourceFile.ID) throws {
        try updateSource(id) { $0.bookmark = bookmark }
    }

    private mutating func updateSource(_ id: SourceFile.ID, _ change: (inout SourceFile) -> Void) throws {
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            throw DocumentPlanError.unknownSourceID(id)
        }
        change(&sources[index])
        // Undo- und Redo-Stapel enthalten eigene Kopien hinzugefügter Quellen; dort ebenfalls ändern, damit ein
        // Redo nicht das alte Bookmark oder Passwort zurückbringt.
        undoStack = undoStack.map { $0.updatingSource(id, change) }
        redoStack = redoStack.map { $0.updatingSource(id, change) }
    }

    // MARK: Operationen

    /// Fügt Seiten an `position` ein (0…Anzahl der Seiten). `addingSources` sind neue Quellen, auf die die Seiten
    /// verweisen dürfen. Die Seiten brauchen neue, eindeutige Kennungen.
    public mutating func insert(_ newPages: [PageRef], at position: Int, addingSources: [SourceFile] = []) throws {
        guard !newPages.isEmpty || !addingSources.isEmpty else { return }
        try perform(.insert(pages: newPages, position: position, addedSources: addingSources))
    }

    /// Fügt alle Seiten einer neuen Quelle an `position` ein, z. B. beim Zusammenführen.
    public mutating func insertPages(of source: SourceFile, at position: Int) throws {
        let newPages = (0..<max(source.pageCount, 0)).map { PageRef(source: source.id, index: $0) }
        try insert(newPages, at: position, addingSources: [source])
    }

    /// Entfernt Seiten. Doppelte Kennungen zählen einmal.
    public mutating func remove(_ ids: [PageRef.ID]) throws {
        let positions = try sortedPositions(of: ids)
        guard !positions.isEmpty else { return }
        try perform(.remove(pages: positions.map { pages[$0] }, positions: positions))
    }

    /// Verschiebt Seiten vor die Seite an `position` (0…Anzahl der Seiten; Anzahl heißt ans Ende). Die
    /// verschobenen Seiten behalten ihre bisherige Reihenfolge untereinander, unabhängig von der Reihenfolge in
    /// `ids`. Ändert sich die Reihenfolge nicht, entsteht keine Operation.
    public mutating func move(_ ids: [PageRef.ID], to position: Int) throws {
        guard (0...pages.count).contains(position) else {
            throw DocumentPlanError.positionOutOfRange(position: position, count: pages.count)
        }
        let positions = try sortedPositions(of: ids)
        guard !positions.isEmpty else { return }
        let operation = PlanOperation.move(ids: positions.map { pages[$0].id }, from: positions, to: position)
        var newPages = pages
        var newSources = sources
        try operation.apply(sources: &newSources, pages: &newPages)
        guard newPages != pages else { return }
        try perform(operation)
    }

    /// Dreht Seiten im Uhrzeigersinn. Doppelte Kennungen zählen einmal.
    public mutating func rotate(_ ids: [PageRef.ID], by rotation: Rotation) throws {
        let positions = try sortedPositions(of: ids)
        guard !positions.isEmpty, rotation != .none else { return }
        try perform(.rotate(ids: positions.map { pages[$0].id }, by: rotation))
    }

    // MARK: Undo und Redo

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Macht die letzte Operation rückgängig. Ohne Operation geschieht nichts.
    public mutating func undo() throws {
        guard let operation = undoStack.last else { return }
        var newSources = sources
        var newPages = pages
        try operation.revert(sources: &newSources, pages: &newPages)
        try commit(sources: newSources, pages: newPages)
        undoStack.removeLast()
        redoStack.append(operation)
    }

    /// Wiederholt die zuletzt rückgängig gemachte Operation. Ohne Operation geschieht nichts.
    public mutating func redo() throws {
        guard let operation = redoStack.last else { return }
        var newSources = sources
        var newPages = pages
        try operation.apply(sources: &newSources, pages: &newPages)
        try commit(sources: newSources, pages: newPages)
        redoStack.removeLast()
        undoStack.append(operation)
    }

    // MARK: Extrahieren

    /// Ein neuer Plan mit den gewählten Seiten in ihrer Reihenfolge in diesem Plan, mit Drehung. Er enthält nur die
    /// Quellen, die er braucht, neue Seitenkennungen und keinen Verlauf. Grundlage für Extrahieren und Teilen.
    public func extracting(_ ids: [PageRef.ID]) throws -> DocumentPlan {
        let positions = try sortedPositions(of: ids)
        guard !positions.isEmpty else { throw DocumentPlanError.emptySelection }
        let newPages = positions.map { pages[$0] }.map {
            PageRef(source: $0.source, index: $0.index, rotation: $0.rotation)
        }
        let usedSources = Set(newPages.map(\.source))
        return try DocumentPlan(sources: sources.filter { usedSources.contains($0.id) }, pages: newPages)
    }

    // MARK: Intern

    /// Wendet eine neue Operation an und legt sie auf den Undo-Stapel. Bei einem Fehler bleibt der Plan unverändert.
    private mutating func perform(_ operation: PlanOperation) throws {
        var newSources = sources
        var newPages = pages
        try operation.apply(sources: &newSources, pages: &newPages)
        try commit(sources: newSources, pages: newPages)
        undoStack.append(operation)
        redoStack.removeAll()
    }

    /// Übernimmt einen neuen Zustand nur, wenn er stimmig ist.
    private mutating func commit(sources newSources: [SourceFile], pages newPages: [PageRef]) throws {
        var candidate = self
        candidate.sources = newSources
        candidate.pages = newPages
        try candidate.validate()
        self = candidate
    }

    /// Positionen der Seiten, aufsteigend, ohne Doppelte. Wirft bei einer unbekannten Kennung.
    private func sortedPositions(of ids: [PageRef.ID]) throws -> [Int] {
        var positions = Set<Int>()
        for id in ids {
            guard let position = position(of: id) else { throw DocumentPlanError.unknownPage(id) }
            positions.insert(position)
        }
        return positions.sorted()
    }

    // MARK: Prüfung

    /// Prüft, ob der Plan in sich stimmig ist. Wirft den ersten gefundenen Fehler.
    public func validate() throws {
        var sourceIDs = Set<SourceFile.ID>()
        for source in sources {
            guard sourceIDs.insert(source.id).inserted else {
                throw DocumentPlanError.duplicateSource(source.id)
            }
            switch source.kind {
            case .pdf where source.pageCount < 1, .image where source.pageCount != 1:
                throw DocumentPlanError.invalidPageCount(source: source.id, pageCount: source.pageCount)
            default:
                break
            }
        }

        var pageIDs = Set<PageRef.ID>()
        for page in pages {
            guard pageIDs.insert(page.id).inserted else {
                throw DocumentPlanError.duplicatePage(page.id)
            }
            guard let source = source(of: page) else {
                throw DocumentPlanError.unknownSource(page: page.id, source: page.source)
            }
            guard (0..<source.pageCount).contains(page.index) else {
                throw DocumentPlanError.pageIndexOutOfRange(
                    page: page.id, index: page.index, pageCount: source.pageCount)
            }
        }
    }
}

// MARK: - Codable mit Prüfung

extension DocumentPlan: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sources, pages, undoStack, redoStack
    }

    // Die Stapel werden nicht vorab geprüft: Passt eine gesicherte Operation nicht zum Plan, schlägt erst ihr
    // Undo oder Redo fehl, und der Plan bleibt dabei unverändert.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(UUID.self, forKey: .id),
            sources: try container.decode([SourceFile].self, forKey: .sources),
            pages: try container.decode([PageRef].self, forKey: .pages))
        undoStack = try container.decode([PlanOperation].self, forKey: .undoStack)
        redoStack = try container.decode([PlanOperation].self, forKey: .redoStack)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sources, forKey: .sources)
        try container.encode(pages, forKey: .pages)
        try container.encode(undoStack, forKey: .undoStack)
        try container.encode(redoStack, forKey: .redoStack)
    }
}

// MARK: - Fehler

/// Ein Plan ist nicht stimmig, oder eine Operation passt nicht zum Plan.
public enum DocumentPlanError: Error, Equatable, LocalizedError {
    case duplicateSource(SourceFile.ID)
    case duplicatePage(PageRef.ID)
    case invalidPageCount(source: SourceFile.ID, pageCount: Int)
    case unknownSource(page: PageRef.ID, source: SourceFile.ID)
    case pageIndexOutOfRange(page: PageRef.ID, index: Int, pageCount: Int)
    case unknownPage(PageRef.ID)
    case unknownSourceID(SourceFile.ID)
    case positionOutOfRange(position: Int, count: Int)
    case emptySelection
    case historyMismatch

    public var errorDescription: String? {
        switch self {
        case .duplicateSource:
            loc("Eine Quelldatei ist doppelt eingetragen.", "A source file is listed twice.")
        case .duplicatePage:
            loc("Eine Seite ist doppelt eingetragen.", "A page is listed twice.")
        case let .invalidPageCount(_, pageCount):
            loc("Eine Quelldatei hat eine ungültige Seitenzahl (\(pageCount)).",
                "A source file has an invalid page count (\(pageCount)).")
        case .unknownSource:
            loc("Eine Seite verweist auf eine unbekannte Quelldatei.", "A page refers to an unknown source file.")
        case let .pageIndexOutOfRange(_, index, pageCount):
            loc("Eine Seite verweist auf Seite \(index + 1), die Quelldatei hat aber nur \(pageCount) Seiten.",
                "A page refers to page \(index + 1), but the source file has only \(pageCount) pages.")
        case .unknownSourceID:
            loc("Die Quelldatei gehört nicht zu diesem Dokument.", "The source file does not belong to this document.")
        case .unknownPage:
            loc("Die Seite gehört nicht zu diesem Dokument.", "The page does not belong to this document.")
        case let .positionOutOfRange(position, count):
            loc("Die Position \(position) liegt außerhalb des Dokuments (\(count) Seiten).",
                "Position \(position) is outside the document (\(count) pages).")
        case .emptySelection:
            loc("Es ist keine Seite ausgewählt.", "No page is selected.")
        case .historyMismatch:
            loc("Der Schritt lässt sich nicht rückgängig machen oder wiederholen, weil er nicht zum Dokument passt.",
                "The step cannot be undone or redone because it does not match the document.")
        }
    }
}
