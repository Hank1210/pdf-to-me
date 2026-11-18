import Foundation
import PDFKit

/// Ein Grund, warum eine geschriebene Datei die Prüfung nicht besteht. Seitenangaben ab 1.
public enum VerificationFailure: Error, Equatable, Sendable {
    case cannotOpen
    /// PDFKit kann die Datei öffnen, qpdf findet aber Fehler im Aufbau.
    case notReadableByQPDF
    case wrongPassword
    case pageCount(expected: Int, actual: Int)
    case textMismatch(page: Int)
    case linksMissing(page: Int, expected: Int, actual: Int)
    case formFieldsMissing(page: Int, expected: [String], actual: [String])
    case outlineMissing(expected: Int, actual: Int)
    /// Felder sind zwar sichtbar, stehen aber nicht im Formularverzeichnis und lassen sich nicht mehr ausfüllen.
    case formFieldsNotFillable(missing: [String])

    /// Fester Name für das Protokoll, ohne Daten (Formularfeldnamen könnten Inhalt sein).
    var logName: StaticString {
        switch self {
        case .cannotOpen: "cannotOpen"
        case .notReadableByQPDF: "notReadableByQPDF"
        case .wrongPassword: "wrongPassword"
        case .pageCount: "pageCount"
        case .textMismatch: "textMismatch"
        case .linksMissing: "linksMissing"
        case .formFieldsMissing: "formFieldsMissing"
        case .outlineMissing: "outlineMissing"
        case .formFieldsNotFillable: "formFieldsNotFillable"
        }
    }

    public var message: String {
        switch self {
        case .cannotOpen:
            loc("Die neue Datei lässt sich nicht öffnen.", "The new file cannot be opened.")
        case .notReadableByQPDF:
            loc("Die neue Datei ist fehlerhaft aufgebaut und lässt sich nicht in jedem PDF-Programm öffnen.",
                "The new file is malformed and cannot be opened by every PDF app.")
        case .wrongPassword:
            loc("Die neue Datei lässt sich mit dem gewählten Passwort nicht öffnen.",
                "The new file cannot be opened with the chosen password.")
        case let .pageCount(expected, actual):
            loc("Die neue Datei hat \(actual) statt \(expected) Seiten.",
                "The new file has \(actual) pages instead of \(expected).")
        case let .textMismatch(page):
            loc("Der Text auf Seite \(page) stimmt nicht mit dem Original überein.",
                "The text on page \(page) does not match the original.")
        case let .linksMissing(page, expected, actual):
            loc("Auf Seite \(page) fehlen Links (\(actual) statt \(expected)).",
                "Links are missing on page \(page) (\(actual) instead of \(expected)).")
        case let .formFieldsMissing(page, _, _):
            loc("Auf Seite \(page) fehlen Formularfelder.", "Form fields are missing on page \(page).")
        case let .formFieldsNotFillable(missing):
            loc("Formularfelder lassen sich in der neuen Datei nicht mehr ausfüllen: "
                + "\(missing.joined(separator: ", ")).",
                "Form fields can no longer be filled in the new file: \(missing.joined(separator: ", ")).")
        case let .outlineMissing(expected, actual):
            loc("Im Inhaltsverzeichnis fehlen Einträge (\(actual) statt \(expected)).",
                "Entries are missing from the table of contents (\(actual) instead of \(expected)).")
        }
    }
}

/// Ein Hinweis, der das Speichern nicht verhindert.
public enum SaveWarning: Equatable, Sendable {
    /// Die neue Datei ist deutlich größer als ihre Quellen zusammen.
    case unexpectedlyLarge(bytes: Int64, sourceBytes: Int64)

    public var message: String {
        switch self {
        case let .unexpectedlyLarge(bytes, sourceBytes):
            let formatter = ByteCountFormatter()
            let size = formatter.string(fromByteCount: bytes)
            let sources = formatter.string(fromByteCount: sourceBytes)
            return loc("Die neue Datei ist mit \(size) deutlich größer als ihre Quellen (\(sources)).",
                       "At \(size), the new file is much larger than its sources (\(sources)).")
        }
    }
}

/// Prüft eine geschriebene Datei gegen das erwartete Dokument, bevor sie an ihrem Ziel landet.
///
/// Maßstab ist das von `PlanAssembler` im Speicher zusammengesetzte Dokument: Was dort steht, muss nach dem Schreiben
/// und erneuten Öffnen noch da sein. In M1b wird zusätzlich mit PDFium geöffnet.
public enum SaveVerifier {
    /// Ab welchem Verhältnis zur Größe der Quellen gewarnt wird, plus ein fester Spielraum für kleine Dateien.
    public static let sizeWarningFactor: Int64 = 2
    public static let sizeWarningSlack: Int64 = 1_000_000

    /// Prüft und gibt alle gefundenen Fehler zurück; leer heißt bestanden.
    public static func failures(
        of url: URL, expected: AssembledDocument, plan: DocumentPlan, contents: SourceContents, password: String?
    ) -> [VerificationFailure] {
        guard let written = PDFDocument(url: url) else { return [.cannotOpen] }
        if written.isLocked {
            guard let password, written.unlock(withPassword: password) else { return [.wrongPassword] }
        }
        let reference = expected.document
        guard written.pageCount == reference.pageCount else {
            return [.pageCount(expected: reference.pageCount, actual: written.pageCount)]
        }
        // Zweite, unabhängige Leseprobe mit qpdf.
        switch QPDFCheck.run(url, password: password) {
        case let .failure(failure):
            return [failure]
        case let .success(check):
            guard check.pageCount == reference.pageCount else {
                return [.pageCount(expected: reference.pageCount, actual: check.pageCount)]
            }
            if check.warnings > 0 {
                Log.shared.warning("qpdf check warnings", ["plan": .id(plan.id), "warnings": .int(check.warnings)])
            }
        }

        var failures: [VerificationFailure] = []
        // Text: gegen eine frische, unabhängige Lesung der Original-Bytes, nicht gegen die Kopie aus der Vorschau.
        // Kopierte PDFKit-Seiten teilen Daten mit der angezeigten Quelle; ihre Textauslese ist kein sicherer Maßstab.
        let originals = freshSources(plan: plan, contents: contents)
        for index in textSamplePositions(plan) {
            let ref = plan.pages[index]
            guard let copy = written.page(at: index) else { continue }
            let expectedText: String?
            if let source = originals[ref.source] {
                expectedText = source.page(at: ref.index)?.string
            } else {
                expectedText = reference.page(at: index)?.string   // Bilder: keine Original-PDF, kein Text
            }
            if normalized(expectedText) != normalized(copy.string) {
                failures.append(.textMismatch(page: index + 1))
            }
        }
        for index in 0..<reference.pageCount {
            guard let original = reference.page(at: index), let copy = written.page(at: index) else { continue }
            let expectedLinks = links(on: original), actualLinks = links(on: copy)
            if actualLinks < expectedLinks {
                failures.append(.linksMissing(page: index + 1, expected: expectedLinks, actual: actualLinks))
            }
            let expectedFields = fieldNames(on: original), actualFields = fieldNames(on: copy)
            if !Set(expectedFields).isSubset(of: Set(actualFields)) {
                failures.append(.formFieldsMissing(page: index + 1, expected: expectedFields, actual: actualFields))
            }
        }
        let expectedOutline = outlineCount(reference.outlineRoot), actualOutline = outlineCount(written.outlineRoot)
        if actualOutline < expectedOutline {
            failures.append(.outlineMissing(expected: expectedOutline, actual: actualOutline))
        }
        let missingFields = fillableFields(expectedIn: plan, contents: contents, reference: reference)
            .subtracting(FormFields.names(at: url, password: password))
        if !missingFields.isEmpty {
            failures.append(.formFieldsNotFillable(missing: missingFields.sorted()))
        }
        return failures
    }

    /// Die PDF-Quellen des Plans, neu aus ihren beim Öffnen gelesenen Bytes geöffnet (unabhängig von den
    /// PDFKit-Objekten, die die App anzeigt), bei Bedarf entsperrt.
    static func freshSources(plan: DocumentPlan, contents: SourceContents) -> [SourceFile.ID: PDFDocument] {
        var documents: [SourceFile.ID: PDFDocument] = [:]
        for source in plan.sourcesInUse {
            guard case let .pdf(_, data) = contents[source.id], let document = PDFDocument(data: data) else { continue }
            if document.isLocked {
                guard let password = source.password, document.unlock(withPassword: password) else { continue }
            }
            documents[source.id] = document
        }
        return documents
    }

    /// Felder, die in einer Quelle im Formularverzeichnis stehen und deren Widget auf einer übernommenen Seite liegt.
    /// Widgets aus Quellen ohne Formularverzeichnis waren schon dort nicht ausfüllbar und zählen nicht.
    static func fillableFields(
        expectedIn plan: DocumentPlan, contents: SourceContents, reference: PDFDocument
    ) -> Set<String> {
        var registered: [SourceFile.ID: Set<String>] = [:]
        for source in plan.sourcesInUse {
            guard case let .pdf(document, _) = contents[source.id], let cgDocument = document.documentRef else {
                continue
            }
            registered[source.id] = FormFields.names(in: cgDocument)
        }
        var expected = Set<String>()
        for (index, ref) in plan.pages.enumerated() {
            guard let fields = registered[ref.source], !fields.isEmpty, let page = reference.page(at: index) else {
                continue
            }
            expected.formUnion(fieldNames(on: page).filter(fields.contains))
        }
        return expected
    }

    /// Hinweise, die das Speichern nicht verhindern.
    public static func warnings(
        of url: URL, plan: DocumentPlan, slack: Int64 = sizeWarningSlack
    ) -> [SaveWarning] {
        guard let bytes = fileSize(url) else { return [] }
        let usedSources = Set(plan.pages.map(\.source))
        let sourceBytes = plan.sources.filter { usedSources.contains($0.id) }
            .compactMap { SourceLoader.resolve($0).flatMap(fileSize) }
            .reduce(0, +)
        guard sourceBytes > 0, bytes > sourceBytes * sizeWarningFactor + slack else { return [] }
        return [.unexpectedlyLarge(bytes: bytes, sourceBytes: sourceBytes)]
    }

    // MARK: Hilfen

    /// Stichproben je Quelle: erste, mittlere und letzte Position, an der Seiten der Quelle stehen.
    static func textSamplePositions(_ plan: DocumentPlan) -> [Int] {
        var positionsBySource: [SourceFile.ID: [Int]] = [:]
        for (position, page) in plan.pages.enumerated() {
            positionsBySource[page.source, default: []].append(position)
        }
        let samples = positionsBySource.values.flatMap { positions in
            [positions.first, positions[positions.count / 2], positions.last].compactMap { $0 }
        }
        return Set(samples).sorted()
    }

    /// Text ohne Leerraum: Zeilenumbrüche und Abstände können sich beim Schreiben ändern, die Zeichen nicht.
    private static func normalized(_ text: String?) -> String {
        (text ?? "").unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init).joined()
    }

    private static func links(on page: PDFPage) -> Int {
        page.annotations.filter { $0.type == "Link" }.count
    }

    private static func fieldNames(on page: PDFPage) -> [String] {
        page.annotations.filter { $0.type == "Widget" }.compactMap(\.fieldName).sorted()
    }

    private static func outlineCount(_ item: PDFOutline?) -> Int {
        guard let item else { return 0 }
        return (0..<item.numberOfChildren).reduce(0) { $0 + 1 + outlineCount(item.child(at: $1)) }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}
