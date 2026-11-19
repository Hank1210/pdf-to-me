import DocKit
import Foundation
import PDFKit

/// Ein aus einem Plan zusammengesetztes `PDFDocument` und die Zuordnung seiner Seiten zum Plan.
public struct AssembledDocument {
    public let document: PDFDocument
    /// `pageIDs[i]` ist die Kennung der Seite an Position `i` im Dokument, in der Reihenfolge des Plans.
    public let pageIDs: [PageRef.ID]

    public func pageID(of page: PDFPage) -> PageRef.ID? {
        let index = document.index(for: page)
        return pageIDs.indices.contains(index) ? pageIDs[index] : nil
    }
}

/// Setzt aus einem Plan und den geladenen Quellen ein `PDFDocument` im Speicher zusammen.
///
/// Grundlage für die Vorschau (zum Schreiben dient `QPDFKitWriter`). Seiten werden strukturell kopiert, nie neu
/// gezeichnet: Text, Links, Anmerkungen und Formularfelder bleiben erhalten. Die Quelldokumente werden nicht
/// verändert.
///
/// - Interne Links werden auf die Seiten des neuen Dokuments umgeschrieben. Zeigt ein Link auf eine Seite, die
///   nicht im Ergebnis steht, wird er entfernt; der Text bleibt.
/// - Das Inhaltsverzeichnis wird aus den Inhaltsverzeichnissen der Quellen übernommen, soweit seine Ziele im
///   Ergebnis stehen. Haben mehrere Quellen eines, steht jedes unter einem Eintrag mit dem Dateinamen.
/// - Kommt eine Quellseite mehrfach vor, zeigen Links und Inhaltsverzeichnis auf ihr erstes Vorkommen.
public enum PlanAssembler {
    public static func assemble(
        _ plan: DocumentPlan, contents: SourceContents
    ) throws -> AssembledDocument {
        let document = PDFDocument()
        var imagePages: [SourceFile.ID: PDFPage] = [:]
        // Quellseite (als Objekt) → erstes Vorkommen im neuen Dokument.
        var firstCopy: [ObjectIdentifier: PDFPage] = [:]
        var copies: [(copy: PDFPage, original: PDFPage)] = []

        for ref in plan.pages {
            guard let source = plan.source(of: ref), let content = contents[ref.source] else {
                throw AssemblyError.missingContent(fileName: plan.source(of: ref)?.displayName ?? "?")
            }
            let page: PDFPage
            switch content {
            case let .pdf(sourceDocument, _):
                guard let original = sourceDocument.page(at: ref.index) else {
                    throw AssemblyError.pageMissing(fileName: source.displayName, page: ref.index + 1)
                }
                page = try copy(original)
                page.rotation = (original.rotation + ref.rotation.degrees) % 360
                if firstCopy[ObjectIdentifier(original)] == nil {
                    firstCopy[ObjectIdentifier(original)] = page
                }
                copies.append((page, original))
            case let .image(image, orientation):
                // Das Bild wird je Quelle nur einmal aufbereitet; jede Verwendung bekommt eine eigene Seite.
                let template = try imagePages[ref.source] ?? ImagePage.makePage(image, orientation: orientation)
                imagePages[ref.source] = template
                page = try copy(template)
                page.rotation = ref.rotation.degrees
            }
            document.insert(page, at: document.pageCount)
        }

        for (page, original) in copies {
            remapLinks(on: page, original: original, firstCopy: firstCopy)
        }
        document.outlineRoot = outline(for: plan, contents: contents, document: document, firstCopy: firstCopy)
        return AssembledDocument(document: document, pageIDs: plan.pages.map(\.id))
    }

    // MARK: Seiten

    /// Kopiert eine Seite. Die Kopie hat eigene Anmerkungsobjekte; Änderungen daran berühren die Quelle nicht
    /// (abgesichert in `PlanAssemblerTests`). Anmerkungen nicht einzeln mit `copy()` kopieren: Dabei verlieren
    /// Links ihr Ziel.
    private static func copy(_ page: PDFPage) throws -> PDFPage {
        guard let copy = page.copy() as? PDFPage else { throw AssemblyError.copyFailed }
        return copy
    }

    /// Schreibt interne Links auf die Seiten des neuen Dokuments um.
    ///
    /// Kopierte Anmerkungen teilen sich in PDFKit intern Daten mit dem Original: Wird das Ziel eines kopierten Links
    /// geändert, verliert auch der Link der Quelle sein Ziel, und das Ziel einer Kopie wird erst beim ersten Zugriff
    /// und dann im falschen Dokument aufgelöst. Deshalb wird das Ziel aus der Originalseite gelesen, der kopierte
    /// Link entfernt und durch einen neuen ersetzt. Externe Links und andere Anmerkungen bleiben unberührt.
    private static func remapLinks(on page: PDFPage, original: PDFPage, firstCopy: [ObjectIdentifier: PDFPage]) {
        let originals = original.annotations
        let copied = page.annotations
        // Die Kopie hat dieselben Anmerkungen in derselben Reihenfolge. Sonst lieber nichts anfassen.
        guard originals.count == copied.count else { return }
        for (source, copy) in zip(originals, copied) {
            let destination = (source.action as? PDFActionGoTo)?.destination ?? source.destination
            guard let destination, let target = destination.page, target.document === original.document else {
                continue
            }
            page.removeAnnotation(copy)
            guard let mapped = firstCopy[ObjectIdentifier(target)] else { continue }
            let newDestination = PDFDestination(page: mapped, at: destination.point)
            newDestination.zoom = destination.zoom
            let link = PDFAnnotation(bounds: source.bounds, forType: .link, withProperties: nil)
            link.border = source.border
            link.action = PDFActionGoTo(destination: newDestination)
            page.addAnnotation(link)
        }
    }

    // MARK: Inhaltsverzeichnis

    private static func outline(
        for plan: DocumentPlan, contents: SourceContents, document: PDFDocument,
        firstCopy: [ObjectIdentifier: PDFPage]
    ) -> PDFOutline? {
        let usedSources = Set(plan.pages.map(\.source))
        var groups: [(source: SourceFile, items: [PDFOutline])] = []
        for source in plan.sources where usedSources.contains(source.id) {
            guard case let .pdf(sourceDocument, _) = contents[source.id], let root = sourceDocument.outlineRoot
            else { continue }
            let items = (0..<root.numberOfChildren).compactMap { root.child(at: $0) }
                .compactMap { copyOutline($0, firstCopy: firstCopy) }
            if !items.isEmpty { groups.append((source, items)) }
        }
        guard !groups.isEmpty else { return nil }

        let root = PDFOutline()
        if groups.count == 1 {
            groups[0].items.forEach { root.insertChild($0, at: root.numberOfChildren) }
        } else {
            for group in groups {
                let item = PDFOutline()
                item.label = group.source.displayName
                if let first = plan.pages.firstIndex(where: { $0.source == group.source.id }),
                   let page = document.page(at: first) {
                    let top = CGPoint(x: 0, y: page.bounds(for: .mediaBox).maxY)
                    item.destination = PDFDestination(page: page, at: top)
                }
                group.items.forEach { item.insertChild($0, at: item.numberOfChildren) }
                root.insertChild(item, at: root.numberOfChildren)
            }
        }
        return root
    }

    /// Kopiert einen Eintrag mit Unterpunkten. Ein Eintrag bleibt, wenn sein Ziel oder eines seiner Unterpunkte im
    /// Ergebnis steht; ohne eigenes Ziel bleibt er als Überschrift.
    private static func copyOutline(_ item: PDFOutline, firstCopy: [ObjectIdentifier: PDFPage]) -> PDFOutline? {
        let children = (0..<item.numberOfChildren).compactMap { item.child(at: $0) }
            .compactMap { copyOutline($0, firstCopy: firstCopy) }
        let destination = item.destination ?? (item.action as? PDFActionGoTo)?.destination
        let mapped = destination?.page.flatMap { firstCopy[ObjectIdentifier($0)] }
        guard mapped != nil || !children.isEmpty else { return nil }

        let copy = PDFOutline()
        copy.label = item.label
        copy.isOpen = item.isOpen
        if let mapped, let destination {
            let newDestination = PDFDestination(page: mapped, at: destination.point)
            newDestination.zoom = destination.zoom
            copy.destination = newDestination
        }
        children.forEach { copy.insertChild($0, at: copy.numberOfChildren) }
        return copy
    }
}

/// Warum sich ein Plan nicht zusammensetzen ließ.
public enum AssemblyError: Error, Equatable, LocalizedError {
    /// Die Quelle ist nicht geladen (z. B. fehlt sie nach einem Neustart).
    case missingContent(fileName: String)
    /// Die geladene Quelle hat weniger Seiten als erwartet.
    case pageMissing(fileName: String, page: Int)
    case copyFailed
    case imagePageFailed
    /// Die Textebene einer erkannten Seite ließ sich nicht erzeugen.
    case textLayerFailed

    public var errorDescription: String? {
        switch self {
        case let .missingContent(name):
            loc("„\(name)“ ist nicht geöffnet.", "“\(name)” is not open.")
        case let .pageMissing(name, page):
            loc("„\(name)“ hat keine Seite \(page) mehr.", "“\(name)” no longer has a page \(page).")
        case .copyFailed:
            loc("Eine Seite ließ sich nicht kopieren.", "A page could not be copied.")
        case .imagePageFailed:
            loc("Aus einem Bild ließ sich keine Seite erzeugen.", "A page could not be created from an image.")
        case .textLayerFailed:
            loc("Die Textebene einer erkannten Seite ließ sich nicht erzeugen.",
                "The text layer of a recognized page could not be created.")
        }
    }
}
