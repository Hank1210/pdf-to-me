import DocKit
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
    /// Ergebnisse der Texterkennung für Seiten mit `PageRef.recognizesText`. Fehlt für eine solche Seite das
    /// Ergebnis, schreibt der Writer nicht (`WriterError.textNotRecognized`): Die Erkennung läuft vorher.
    public var textLayers: TextRecognitionCache?
    /// Verlustfrei verkleinern (Objekt-Streams, Neukomprimierung, unbenutzte Ressourcen entfernen). Inhalte, Links,
    /// Formulare und Inhaltsverzeichnis bleiben unverändert; deshalb immer an.
    public var compact: Bool

    public init(password: String? = nil, textLayers: TextRecognitionCache? = nil, compact: Bool = true) {
        self.password = password
        self.textLayers = textLayers
        self.compact = compact
    }
}

/// Schreibt einen Plan als neue PDF-Datei.
///
/// Umsetzung: `QPDFKitWriter` (qpdf). `PDFDocument.write` wird nie zum Speichern benutzt. Ein Writer schreibt nur an
/// eine Stelle, an der noch keine Datei liegt; Zielnamen, Prüfung und atomares Verschieben übernimmt die
/// Speicher-Pipeline.
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
    /// Eine Quelle ließ sich beim Schreiben nicht lesen (sie war beim Öffnen lesbar; eher ein Fehler im Writer).
    case sourceUnreadable(fileName: String, reason: String)
    /// Der Writer meldet einen Fehler; `reason` ist seine (englische) Beschreibung.
    case engineFailed(fileName: String, reason: String)
    /// Seite `page` (ab 1) soll eine Textebene bekommen, ihr Text ist aber noch nicht erkannt.
    case textNotRecognized(page: Int)

    public var errorDescription: String? {
        switch self {
        case let .destinationExists(name):
            loc("„\(name)“ gibt es schon. Die Datei wird nicht überschrieben.",
                "“\(name)” already exists. The file is not overwritten.")
        case .noPages:
            loc("Das Dokument hat keine Seiten.", "The document has no pages.")
        case let .writeFailed(name):
            loc("„\(name)“ ließ sich nicht schreiben.", "“\(name)” could not be written.")
        case let .sourceUnreadable(name, reason):
            loc("„\(name)“ ließ sich beim Speichern nicht lesen (\(reason)).",
                "“\(name)” could not be read while saving (\(reason)).")
        case let .engineFailed(name, reason):
            loc("„\(name)“ ließ sich nicht schreiben (\(reason)).", "“\(name)” could not be written (\(reason)).")
        case let .textNotRecognized(page):
            loc("Der Text auf Seite \(page) ist noch nicht erkannt.", "The text on page \(page) has not been recognized yet.")
        }
    }
}
