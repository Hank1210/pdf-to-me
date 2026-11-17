import Foundation

/// Die geladenen Inhalte der Quellen eines Plans, nach Kennung der Quelle.
public typealias SourceContents = [SourceFile.ID: LoadedSource.Content]

/// Was ein Writer kann. Die Oberfläche blendet Funktionen aus, die das aktive Backend nicht kann.
public struct WriterCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Zusammenführen, Teilen, Sortieren, Drehen, Löschen, Extrahieren, Bilder als Seiten.
    public static let pageOperations = WriterCapabilities(rawValue: 1 << 0)
}

/// Einstellungen für eine zu schreibende Datei.
public struct WriteOptions: Sendable {
    /// Schützt die neue Datei mit diesem Passwort (Öffnen und Rechte). `nil`: ohne Passwort.
    public var password: String?

    public init(password: String? = nil) {
        self.password = password
    }
}

/// Schreibt einen Plan als neue PDF-Datei.
///
/// Umsetzungen: `PDFKitWriter` (Übergang bis M1b), `PDFiumWriter` (Ziel). Ein Writer schreibt nur an eine Stelle, an
/// der noch keine Datei liegt; Zielnamen, Prüfung und atomares Verschieben übernimmt die Speicher-Pipeline.
public protocol PDFWriting {
    var capabilities: WriterCapabilities { get }

    func compose(_ plan: DocumentPlan, contents: SourceContents, to url: URL, options: WriteOptions) throws
}

/// Warum eine Datei nicht geschrieben wurde.
public enum WriterError: Error, Equatable, LocalizedError {
    /// Am Ziel liegt schon eine Datei. Writer überschreiben nie.
    case destinationExists(fileName: String)
    case noPages
    case writeFailed(fileName: String)

    public var errorDescription: String? {
        switch self {
        case let .destinationExists(name):
            loc("„\(name)“ gibt es schon. Die Datei wird nicht überschrieben.",
                "“\(name)” already exists. The file is not overwritten.")
        case .noPages:
            loc("Das Dokument hat keine Seiten.", "The document has no pages.")
        case let .writeFailed(name):
            loc("„\(name)“ ließ sich nicht schreiben.", "“\(name)” could not be written.")
        }
    }
}
