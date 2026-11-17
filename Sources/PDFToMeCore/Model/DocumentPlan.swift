import Foundation

/// Der Arbeitsstand eines Fensters: Quellen und die Liste der Ergebnisseiten.
///
/// Der Plan ist immer in sich stimmig (siehe `validate`). Das gilt auch beim Dekodieren einer Sitzungsdatei:
/// Eine beschädigte Datei wird abgelehnt statt halb übernommen. Erst beim Speichern entsteht aus dem Plan eine PDF.
public struct DocumentPlan: Identifiable, Hashable, Sendable {
    /// Kennung des Arbeitsstands, zugleich Name der Sitzungsdatei `Sessions/<id>.json`.
    public let id: UUID
    public private(set) var sources: [SourceFile]
    public private(set) var pages: [PageRef]

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
                throw DocumentPlanError.pageIndexOutOfRange(page: page.id, index: page.index, pageCount: source.pageCount)
            }
        }
    }
}

// MARK: - Codable mit Prüfung

extension DocumentPlan: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sources, pages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(UUID.self, forKey: .id),
            sources: try container.decode([SourceFile].self, forKey: .sources),
            pages: try container.decode([PageRef].self, forKey: .pages))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sources, forKey: .sources)
        try container.encode(pages, forKey: .pages)
    }
}

// MARK: - Fehler

/// Ein Plan ist nicht stimmig. Tritt nur bei Programmfehlern oder beschädigten Sitzungsdateien auf.
public enum DocumentPlanError: Error, Equatable, LocalizedError {
    case duplicateSource(SourceFile.ID)
    case duplicatePage(PageRef.ID)
    case invalidPageCount(source: SourceFile.ID, pageCount: Int)
    case unknownSource(page: PageRef.ID, source: SourceFile.ID)
    case pageIndexOutOfRange(page: PageRef.ID, index: Int, pageCount: Int)

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
        }
    }
}
