import Foundation

/// Ein Teil beim Teilen: Seiten `first…last` (ab 1) in der aktuellen Reihenfolge des Dokuments.
public struct SplitPart: Equatable, Hashable, Sendable {
    public let first: Int
    public let last: Int

    public init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }

    /// Bezeichnung im Dateinamen: `1–3` (mit Gedankenstrich) oder `5` für eine einzelne Seite.
    public var label: String {
        first == last ? "\(first)" : "\(first)–\(last)"
    }
}

/// Teilt ein Dokument in mehrere Dateien. Jede Teil-Datei läuft einzeln durch die Speicher-Pipeline.
public enum Splitter {
    // MARK: Teile bestimmen

    /// Liest Seitenangaben wie `1–3, 4–9`, `5`, `7-` (bis zum Ende). Trennzeichen sind Komma und Semikolon;
    /// Bereiche mit Bindestrich, Gedankenstrich oder Geviertstrich. Jede Angabe ergibt eine Datei.
    public static func parts(fromRanges text: String, pageCount: Int) throws -> [SplitPart] {
        let entries = text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard entries.contains(where: { !$0.isEmpty }) else { throw SplitError.noRanges }

        return try entries.filter { !$0.isEmpty }.map { entry in
            let bounds = entry.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                .flatMap { $0.split(separator: "–", omittingEmptySubsequences: false) }
                .flatMap { $0.split(separator: "—", omittingEmptySubsequences: false) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let first: Int, last: Int
            switch bounds.count {
            case 1:
                guard let page = Int(bounds[0]) else { throw SplitError.invalidEntry(entry) }
                (first, last) = (page, page)
            case 2:
                guard let lower = Int(bounds[0]) else { throw SplitError.invalidEntry(entry) }
                guard let upper = bounds[1].isEmpty ? pageCount : Int(bounds[1]) else {
                    throw SplitError.invalidEntry(entry)
                }
                (first, last) = (lower, upper)
            default:
                throw SplitError.invalidEntry(entry)
            }
            guard first <= last else { throw SplitError.reversedRange(entry) }
            guard first >= 1, last <= pageCount else {
                throw SplitError.outOfRange(entry, pageCount: pageCount)
            }
            return SplitPart(first: first, last: last)
        }
    }

    /// Teile zu je `pagesPerPart` Seiten; der letzte Teil kann kürzer sein.
    public static func parts(every pagesPerPart: Int, pageCount: Int) throws -> [SplitPart] {
        guard pagesPerPart >= 1 else { throw SplitError.invalidPartSize }
        guard pageCount >= 1 else { throw SplitError.noRanges }
        return stride(from: 1, through: pageCount, by: pagesPerPart).map {
            SplitPart(first: $0, last: min($0 + pagesPerPart - 1, pageCount))
        }
    }

    // MARK: Speichern

    /// Ergebnis eines Teils: gespeichert oder mit Fehler.
    public struct PartResult {
        public let part: SplitPart
        public let result: Result<SaveResult, Error>
    }

    /// Speichert jeden Teil als eigene Datei `<stem> (<label>).pdf` in `directory`, bei Kollision nummeriert.
    ///
    /// Schlägt ein Teil fehl, werden die übrigen trotzdem gespeichert; bereits geschriebene bleiben erhalten.
    /// `stem` ist der Name der Ausgangsdatei ohne Endung und ohne Kennzeichnung als bearbeitet.
    public static func save(
        _ plan: DocumentPlan, contents: SourceContents, parts: [SplitPart], in directory: URL, stem: String,
        pipeline: SavePipeline, options: WriteOptions = WriteOptions()
    ) -> [PartResult] {
        parts.map { part in
            let result = Result<SaveResult, Error> {
                guard part.first >= 1, part.last <= plan.pages.count, part.first <= part.last else {
                    throw SplitError.outOfRange(part.label, pageCount: plan.pages.count)
                }
                let ids = plan.pages[(part.first - 1)...(part.last - 1)].map(\.id)
                let partPlan = try plan.extracting(ids)
                return try pipeline.save(
                    partPlan, contents: contents, in: directory, baseName: "\(stem) (\(part.label))",
                    options: options)
            }
            return PartResult(part: part, result: result)
        }
    }

    /// Name ohne Endung für die Teil-Dateien, z. B. `Vertrag (bearbeitet).pdf` → `Vertrag`.
    public static func stem(forOriginal fileName: String) -> String {
        FileNaming.stem(of: fileName)
    }
}

/// Warum sich die Teilung nicht bestimmen ließ. Die Meldungen nennen die fehlerhafte Angabe.
public enum SplitError: Error, Equatable, LocalizedError {
    case noRanges
    case invalidEntry(String)
    case reversedRange(String)
    case outOfRange(String, pageCount: Int)
    case invalidPartSize

    public var errorDescription: String? {
        switch self {
        case .noRanges:
            loc("Bitte geben Sie mindestens eine Seite oder einen Bereich an, z. B. „1–3, 4–9“.",
                "Please enter at least one page or range, for example “1–3, 4–9”.")
        case let .invalidEntry(entry):
            loc("„\(entry)“ ist keine gültige Seitenangabe. Möglich sind z. B. „5“, „1–3“ oder „7–“.",
                "“\(entry)” is not a valid page entry. Examples: “5”, “1–3” or “7–”.")
        case let .reversedRange(entry):
            loc("Im Bereich „\(entry)“ ist die erste Seite größer als die letzte.",
                "In the range “\(entry)”, the first page is greater than the last.")
        case let .outOfRange(entry, pageCount):
            loc("„\(entry)“ liegt außerhalb des Dokuments (Seiten 1–\(pageCount)).",
                "“\(entry)” is outside the document (pages 1–\(pageCount)).")
        case .invalidPartSize:
            loc("Ein Teil muss mindestens eine Seite haben.", "Each part must have at least one page.")
        }
    }
}
