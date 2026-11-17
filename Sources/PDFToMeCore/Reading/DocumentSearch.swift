import Foundation
import PDFKit

/// Ein Treffer der Suche mit einem kurzen Textausschnitt.
public struct SearchMatch: Identifiable {
    public let id: Int
    public let pageIndex: Int
    public let selection: PDFSelection
    /// Der Treffer mit etwas Text davor und danach, auf eine Zeile gebracht.
    public let snippet: String
}

/// Die Treffer auf einer Seite.
public struct PageMatches: Identifiable {
    public var id: Int { pageIndex }
    public let pageIndex: Int
    public let matches: [SearchMatch]
}

/// Suche über das ganze Dokument; die Treffer werden nach Seiten aufgelistet (README).
public enum DocumentSearch {
    /// Mehr Treffer werden nicht aufgelistet, damit die Liste bedienbar bleibt.
    public static let maximumMatches = 1000
    static let contextLength = 30

    /// Sucht ohne Rücksicht auf Groß- und Kleinschreibung und Akzente. Leere Suchbegriffe ergeben nichts.
    public static func search(_ query: String, in document: PDFDocument) -> [PageMatches] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let selections = document.findString(trimmed, withOptions: [.caseInsensitive, .diacriticInsensitive])

        var byPage: [Int: [SearchMatch]] = [:]
        for (number, selection) in selections.prefix(maximumMatches).enumerated() {
            guard let page = selection.pages.first else { continue }
            let pageIndex = document.index(for: page)
            byPage[pageIndex, default: []].append(
                SearchMatch(id: number, pageIndex: pageIndex, selection: selection, snippet: snippet(for: selection)))
        }
        return byPage.keys.sorted().map { PageMatches(pageIndex: $0, matches: byPage[$0] ?? []) }
    }

    /// Anzahl aller Treffer, auch über `maximumMatches` hinaus nicht mehr als gefunden.
    public static func count(_ results: [PageMatches]) -> Int {
        results.reduce(0) { $0 + $1.matches.count }
    }

    static func snippet(for selection: PDFSelection) -> String {
        let match = selection.string ?? ""
        guard let context = selection.copy() as? PDFSelection else { return match }
        context.extend(atStart: contextLength)
        context.extend(atEnd: contextLength)
        let text = (context.string ?? match)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? match : text
    }
}
