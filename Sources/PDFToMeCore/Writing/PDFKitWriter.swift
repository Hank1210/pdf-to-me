import Foundation
import PDFKit

/// Schreibt einen Plan über PDFKit: `PlanAssembler` setzt das Dokument zusammen, `PDFDocument.write` speichert es.
///
/// **Nur ein Übergang bis M1b, nie in einer veröffentlichten Version** (siehe `CLAUDE.md`, Regel 3). PDFKit schreibt
/// die Seiten zwar strukturell, ist beim Schreiben aber weniger verlässlich als PDFium. Deshalb läuft jede damit
/// geschriebene Datei durch die Prüf-Pipeline. Ab M1b wird `PDFiumWriter` Standard.
public struct PDFKitWriter: PDFWriting {
    public let capabilities: WriterCapabilities = [.pageOperations]

    public init() {}

    public func compose(_ plan: DocumentPlan, contents: SourceContents, to url: URL, options: WriteOptions) throws {
        let fileName = url.lastPathComponent
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WriterError.destinationExists(fileName: fileName)
        }
        guard !plan.pages.isEmpty else { throw WriterError.noPages }

        let document = try PlanAssembler.assemble(plan, contents: contents).document
        document.documentAttributes = Self.attributes(for: plan, contents: contents)

        var writeOptions: [PDFDocumentWriteOption: Any] = [:]
        if let password = options.password, !password.isEmpty {
            writeOptions[.userPasswordOption] = password
            writeOptions[.ownerPasswordOption] = password
        }
        guard document.write(to: url, withOptions: writeOptions) else {
            // Eine halb geschriebene Datei nicht liegen lassen.
            try? FileManager.default.removeItem(at: url)
            throw WriterError.writeFailed(fileName: fileName)
        }
    }

    /// Titel, Autor, Thema und Stichwörter der ersten PDF-Quelle; als Ersteller „PDF to me“.
    static func attributes(for plan: DocumentPlan, contents: SourceContents) -> [AnyHashable: Any] {
        var attributes: [AnyHashable: Any] = [:]
        let firstPDF = plan.pages.lazy.compactMap { page -> PDFDocument? in
            if case let .pdf(document) = contents[page.source] { return document }
            return nil
        }.first
        let keys: [PDFDocumentAttribute] = [.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute]
        for key in keys {
            if let value = firstPDF?.documentAttributes?[key] { attributes[key] = value }
        }
        attributes[PDFDocumentAttribute.creatorAttribute] = AppIdentity.name
        return attributes
    }
}
