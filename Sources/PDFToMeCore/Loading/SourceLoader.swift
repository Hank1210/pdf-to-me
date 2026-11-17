import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Eine geöffnete Quelle: die Beschreibung für den Plan und der geladene Inhalt für Vorschau und Speichern.
public struct LoadedSource {
    public enum Content {
        /// Entsperrt, falls die PDF verschlüsselt ist.
        case pdf(PDFDocument)
        /// Das Bild und seine EXIF-Ausrichtung; die Ausrichtung wird erst beim Anzeigen und Speichern angewendet.
        case image(CGImage, orientation: CGImagePropertyOrientation)
    }

    public let source: SourceFile
    public let content: Content
}

/// Ob eine gemerkte Quelle noch da ist und unverändert ist.
public enum SourceAvailability: Equatable, Sendable {
    case available(URL)
    /// Die Datei ist da, ihr Inhalt hat sich aber seit dem Öffnen geändert.
    case changed(URL)
    /// Die Datei ist nicht mehr auffindbar (gelöscht, auf ein anderes Volume verschoben, Volume nicht verbunden).
    case missing
}

/// Öffnet PDFs und Bilder als Quellen. Liest Dateien nur, verändert sie nie.
public enum SourceLoader {
    /// Bildformate, die sich als Seiten einfügen lassen (README: JPEG, PNG, HEIC).
    public static let supportedImageTypes: Set<UTType> = [.jpeg, .png, .heic]

    /// Öffnet eine Datei als neue Quelle.
    ///
    /// Die Datei wird einmal gelesen; Prüfsumme und Inhalt stammen aus denselben Bytes. Die Art (PDF oder Bild)
    /// wird am Inhalt erkannt, nicht an der Endung.
    public static func load(_ url: URL, password: String? = nil) throws -> LoadedSource {
        let data = try read(url)
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw SourceLoadError.unreadable(fileName: url.lastPathComponent, reason: error.localizedDescription)
        }
        return try makeSource(
            id: UUID(), data: data, fileName: url.lastPathComponent, bookmark: bookmark, password: password)
    }

    /// Öffnet eine gemerkte Quelle erneut, z. B. nach einem Neustart. Kennung, Name und Bookmark bleiben gleich.
    /// Wirft, wenn die Datei fehlt oder sich ihr Inhalt geändert hat.
    public static func reopen(_ source: SourceFile, password: String? = nil) throws -> LoadedSource {
        guard let url = resolve(source) else { throw SourceLoadError.missing(fileName: source.displayName) }
        let data = try withAccess(to: url) { try read(url) }
        guard sha256(of: data) == source.sha256 else {
            throw SourceLoadError.changedSinceOpened(fileName: source.displayName)
        }
        return try makeSource(
            id: source.id, data: data, fileName: source.displayName, bookmark: source.bookmark,
            password: password ?? source.password)
    }

    /// Prüft, ob eine gemerkte Quelle noch auffindbar und unverändert ist, ohne sie zu öffnen.
    public static func availability(of source: SourceFile) -> SourceAvailability {
        guard let url = resolve(source) else { return .missing }
        guard let data = try? withAccess(to: url, { try read(url) }) else { return .missing }
        return sha256(of: data) == source.sha256 ? .available(url) : .changed(url)
    }

    /// Der aktuelle Ort einer gemerkten Quelle, oder `nil`, wenn sie nicht mehr auffindbar ist.
    public static func resolve(_ source: SourceFile) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: source.bookmark, options: [.withSecurityScope], relativeTo: nil,
            bookmarkDataIsStale: &isStale),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// SHA-256 als Hex-Text in Kleinbuchstaben.
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Intern

    private static func read(_ url: URL) throws -> Data {
        let fileName = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw SourceLoadError.missing(fileName: fileName)
        }
        guard !isDirectory.boolValue else { throw SourceLoadError.unsupportedFileType(fileName: fileName) }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SourceLoadError.unreadable(fileName: fileName, reason: error.localizedDescription)
        }
    }

    private static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private static func makeSource(
        id: UUID, data: Data, fileName: String, bookmark: Data, password: String?
    ) throws -> LoadedSource {
        guard !data.isEmpty else { throw SourceLoadError.emptyFile(fileName: fileName) }
        let hash = sha256(of: data)

        if looksLikePDF(data) {
            let (document, usedPassword) = try openPDF(data, fileName: fileName, password: password)
            let source = SourceFile(
                id: id, kind: .pdf, displayName: fileName, bookmark: bookmark, sha256: hash,
                pageCount: document.pageCount, password: usedPassword)
            return LoadedSource(source: source, content: .pdf(document))
        }

        if let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
           let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
           let type = UTType(typeIdentifier) {
            guard supportedImageTypes.contains(where: { type.conforms(to: $0) }) else {
                throw SourceLoadError.unsupportedFileType(fileName: fileName)
            }
            guard CGImageSourceGetCount(imageSource) > 0,
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
            else { throw SourceLoadError.damagedImage(fileName: fileName) }
            let source = SourceFile(
                id: id, kind: .image, displayName: fileName, bookmark: bookmark, sha256: hash, pageCount: 1)
            return LoadedSource(source: source, content: .image(image, orientation: orientation(of: imageSource)))
        }

        if (fileName as NSString).pathExtension.lowercased() == "pdf" {
            throw SourceLoadError.notAPDF(fileName: fileName)
        }
        throw SourceLoadError.unsupportedFileType(fileName: fileName)
    }

    /// Eine PDF beginnt mit `%PDF-`; manche Erzeuger setzen davor ein paar Bytes Müll, daher die ersten 1024 Bytes.
    private static func looksLikePDF(_ data: Data) -> Bool {
        data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    private static func openPDF(_ data: Data, fileName: String, password: String?) throws
        -> (PDFDocument, password: String?) {
        guard let document = PDFDocument(data: data) else { throw SourceLoadError.damagedPDF(fileName: fileName) }
        var usedPassword: String?
        if document.isLocked {
            guard let password, !password.isEmpty else {
                throw SourceLoadError.passwordRequired(fileName: fileName)
            }
            guard document.unlock(withPassword: password) else {
                throw SourceLoadError.wrongPassword(fileName: fileName)
            }
            usedPassword = password
        }
        guard document.pageCount > 0 else { throw SourceLoadError.noPages(fileName: fileName) }
        return (document, usedPassword)
    }

    private static func orientation(of imageSource: CGImageSource) -> CGImagePropertyOrientation {
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let raw = properties?[kCGImagePropertyOrientation] as? UInt32
        return raw.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
    }
}

/// Warum sich eine Datei nicht als Quelle öffnen ließ. Die Meldungen nennen Datei und Ursache.
public enum SourceLoadError: Error, Equatable, LocalizedError {
    case missing(fileName: String)
    case unreadable(fileName: String, reason: String)
    case emptyFile(fileName: String)
    case notAPDF(fileName: String)
    case damagedPDF(fileName: String)
    case noPages(fileName: String)
    case passwordRequired(fileName: String)
    case wrongPassword(fileName: String)
    case damagedImage(fileName: String)
    case unsupportedFileType(fileName: String)
    case changedSinceOpened(fileName: String)

    /// Ob die App nach einem Passwort fragen soll.
    public var needsPassword: Bool {
        switch self {
        case .passwordRequired, .wrongPassword: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .missing(name):
            loc("„\(name)“ wurde nicht gefunden. Die Datei wurde verschoben, umbenannt oder gelöscht.",
                "“\(name)” was not found. The file was moved, renamed or deleted.")
        case let .unreadable(name, reason):
            loc("„\(name)“ lässt sich nicht lesen: \(reason)", "“\(name)” cannot be read: \(reason)")
        case let .emptyFile(name):
            loc("„\(name)“ ist leer.", "“\(name)” is empty.")
        case let .notAPDF(name):
            loc("„\(name)“ ist keine PDF-Datei, obwohl der Name auf .pdf endet.",
                "“\(name)” is not a PDF file, although its name ends in .pdf.")
        case let .damagedPDF(name):
            loc("„\(name)“ ist beschädigt und lässt sich nicht öffnen. Versuchen Sie, die Datei in Vorschau zu "
                + "öffnen; gelingt das auch dort nicht, ist die Datei selbst fehlerhaft.",
                "“\(name)” is damaged and cannot be opened. Try opening it in Preview; if Preview cannot open it "
                + "either, the file itself is the problem.")
        case let .noPages(name):
            loc("„\(name)“ enthält keine Seiten.", "“\(name)” contains no pages.")
        case let .passwordRequired(name):
            loc("„\(name)“ ist mit einem Passwort geschützt.", "“\(name)” is protected by a password.")
        case let .wrongPassword(name):
            loc("Das Passwort für „\(name)“ ist falsch.", "The password for “\(name)” is wrong.")
        case let .damagedImage(name):
            loc("Das Bild „\(name)“ ist beschädigt.", "The image “\(name)” is damaged.")
        case let .unsupportedFileType(name):
            loc("„\(name)“ wird nicht unterstützt. Möglich sind PDFs und Bilder im Format JPEG, PNG oder HEIC.",
                "“\(name)” is not supported. You can use PDFs and JPEG, PNG or HEIC images.")
        case let .changedSinceOpened(name):
            loc("„\(name)“ wurde seit dem Öffnen verändert.", "“\(name)” was changed after it was opened.")
        }
    }
}
