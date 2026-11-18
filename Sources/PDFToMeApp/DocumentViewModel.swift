import AppKit
import Observation
import PDFKit
import PDFToMeCore

/// Seitenaktionen, die das Fenster ausführt (mit Undo, Fehlermeldungen und Dialogen).
@MainActor
protocol PageCommands: AnyObject {
    func movePages(_ ids: [PageRef.ID], to position: Int)
    func insertFiles(_ urls: [URL], at position: Int)
    func rotatePages(_ ids: [PageRef.ID], by rotation: Rotation)
    func deletePages(_ ids: [PageRef.ID])
    func extractPages(_ ids: [PageRef.ID])
    func printPages(_ ids: [PageRef.ID])
}

/// Zustand eines Dokumentfensters für die Ansichten. Die Logik liegt im Core (`WorkingDocument`, `DocumentSearch`);
/// hier wird nur verbunden und angezeigt.
@MainActor
@Observable
final class DocumentViewModel {
    enum SidebarMode: Hashable {
        case thumbnails, outline, search
    }

    @ObservationIgnored let working: WorkingDocument
    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored weak var commands: PageCommands?

    var sidebarMode: SidebarMode = .thumbnails
    /// Erhöht sich bei jeder neuen Vorschau, damit Miniaturen neu gezeichnet werden.
    private(set) var previewVersion = 0
    private(set) var pageIDs: [PageRef.ID] = []
    private(set) var outline: [OutlineEntry] = []
    /// Je Seite die Nummer ihrer Quelle für den Farbmarker und der Dateiname für den Tooltip.
    private(set) var pageSources: [(colorIndex: Int, name: String)] = []
    /// Farbmarker nur, wenn Seiten aus mehr als einer Quelle stammen.
    private(set) var showsSourceMarkers = false
    private(set) var currentPageIndex = 0
    /// Ausgewählte Miniaturen. Folgt beim Blättern der aktuellen Seite, solange nicht mehrere ausgewählt sind.
    var selectedPages: Set<PageRef.ID> = []

    private(set) var searchQuery = ""
    private(set) var searchResults: [PageMatches] = []
    var selectedMatch: Int?

    init(working: WorkingDocument) {
        self.working = working
        refreshFromPreview()
    }

    var document: PDFDocument { working.preview.document }

    func page(at index: Int) -> PDFPage? { document.page(at: index) }

    // MARK: Vorschau

    /// Nach einer Änderung am Dokument: neue Vorschau anzeigen, die aktuelle Seite möglichst halten.
    func previewDidChange() {
        let currentID = pageIDs.indices.contains(currentPageIndex) ? pageIDs[currentPageIndex] : nil
        refreshFromPreview()
        pdfView?.document = document
        if let currentID, let index = pageIDs.firstIndex(of: currentID) { go(toPage: index) }
        if !searchQuery.isEmpty { search(searchQuery) }
    }

    private func refreshFromPreview() {
        pageIDs = working.preview.pageIDs
        let plan = working.plan
        pageSources = plan.pages.map { page in
            let index = plan.sources.firstIndex { $0.id == page.source } ?? 0
            return (index, plan.source(of: page)?.displayName ?? "")
        }
        showsSourceMarkers = plan.sourcesInUse.count > 1
        outline = OutlineEntry.entries(of: document)
        selectedPages.formIntersection(pageIDs)
        previewVersion += 1
    }

    // MARK: Navigation

    func go(toPage index: Int) {
        guard let page = page(at: index) else { return }
        pdfView?.go(to: page)
    }

    /// Von der `PDFView` gemeldet, wenn die sichtbare Seite wechselt.
    func pageDidChange(to index: Int) {
        currentPageIndex = index
        if selectedPages.count <= 1, pageIDs.indices.contains(index) {
            selectedPages = [pageIDs[index]]
        }
    }

    /// Von der Seitenleiste gemeldet, wenn eine einzelne Miniatur gewählt wurde.
    func thumbnailSelectionDidChange() {
        guard selectedPages.count == 1, let id = selectedPages.first, let index = pageIDs.firstIndex(of: id),
              index != currentPageIndex
        else { return }
        go(toPage: index)
    }

    // MARK: Seitenaktionen

    /// Die Seiten, auf die sich eine Aktion bezieht: die Auswahl in Dokumentreihenfolge, sonst die aktuelle Seite.
    var targetPageIDs: [PageRef.ID] {
        let selected = pageIDs.filter { selectedPages.contains($0) }
        if !selected.isEmpty { return selected }
        return pageIDs.indices.contains(currentPageIndex) ? [pageIDs[currentPageIndex]] : []
    }

    /// Einfügestelle für neue Dateien: hinter der letzten ausgewählten Seite, sonst hinter der aktuellen.
    var insertPosition: Int {
        let positions = targetPageIDs.compactMap { pageIDs.firstIndex(of: $0) }
        return (positions.max() ?? pageIDs.count - 1) + 1
    }

    // MARK: Suche

    func search(_ query: String) {
        searchQuery = query
        searchResults = DocumentSearch.search(query, in: document)
        selectedMatch = nil
        pdfView?.highlightedSelections = searchResults.flatMap { $0.matches.map(\.selection) }.map {
            $0.color = .findHighlightColor
            return $0
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            if sidebarMode == .search { sidebarMode = .thumbnails }
        } else {
            sidebarMode = .search
        }
    }

    func show(matchID: Int) {
        guard let match = searchResults.lazy.flatMap(\.matches).first(where: { $0.id == matchID }) else { return }
        pdfView?.setCurrentSelection(match.selection, animate: false)
        pdfView?.go(to: match.selection)
    }

    var matchCount: Int { DocumentSearch.count(searchResults) }
}
