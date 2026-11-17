import Foundation
import PDFKit

/// Ein Eintrag im Inhaltsverzeichnis, als einfacher Baum für die Seitenleiste.
public struct OutlineEntry: Identifiable, Hashable {
    /// Laufende Nummer in der Reihenfolge des Baums; eindeutig innerhalb eines Dokuments.
    public let id: Int
    public let title: String
    /// Zielseite (ab 0), oder `nil` bei einer reinen Überschrift.
    public let pageIndex: Int?
    /// Unterpunkte, oder `nil` bei einem Blatt (so erwartet es SwiftUIs `OutlineGroup`).
    public let children: [OutlineEntry]?

    /// Die Einträge eines Dokuments, ohne den unsichtbaren Wurzeleintrag. Leer, wenn es keines hat.
    public static func entries(of document: PDFDocument) -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var counter = 0
        return children(of: root, in: document, counter: &counter)
    }

    private static func children(of item: PDFOutline, in document: PDFDocument, counter: inout Int)
        -> [OutlineEntry] {
        (0..<item.numberOfChildren).compactMap { item.child(at: $0) }.map { child in
            counter += 1
            let id = counter
            let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
            let pageIndex = destination?.page.map { document.index(for: $0) }
            let nested = children(of: child, in: document, counter: &counter)
            return OutlineEntry(
                id: id, title: child.label ?? "", pageIndex: pageIndex.flatMap { $0 == NSNotFound ? nil : $0 },
                children: nested.isEmpty ? nil : nested)
        }
    }
}
