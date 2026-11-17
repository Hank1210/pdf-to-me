import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Erzeugt die Test-PDFs und Testbilder zur Laufzeit in einem eigenen temporären Ordner.
///
/// Es liegt bewusst keine Testdatei im Repo: Alles ist selbst erzeugt, frei von Lizenzfragen und von persönlichen
/// Daten (siehe `Tests/Corpus/SOURCES.md`). Jede Datei trägt prüfbare Merkmale, z. B. einen Text je Seite wie
/// `Contract page 3`. `CorpusTests` sichert ab, dass die Dateien diese Merkmale wirklich haben.
///
/// Hinweis: Das Erzeugen mit CoreGraphics und `PDFDocument.write` ist hier erlaubt, weil es nur Testdaten herstellt.
/// Für das Zusammenführen und Teilen in der App gelten die Regeln aus `CLAUDE.md`.
final class TestCorpus {
    /// A4 hoch in Punkten.
    static let a4 = CGSize(width: 595, height: 842)
    static let a4Landscape = CGSize(width: 842, height: 595)

    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFToMeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Löscht den Ordner mit allen erzeugten Dateien.
    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func url(_ fileName: String) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Der Text, den `pdf(named:pages:)` auf Seite `number` (ab 1) schreibt.
    static func marker(_ name: String, page number: Int) -> String {
        "\(name) page \(number)"
    }

    // MARK: PDFs

    /// Eine PDF mit `pages` Seiten. Jede Seite trägt den Text `"<name> page <n>"`. `sizes` wird reihum verwendet.
    @discardableResult
    func pdf(named name: String, pages: Int, sizes: [CGSize] = [a4], password: String? = nil) throws -> URL {
        let url = url("\(name).pdf")
        try writePDF(to: url, password: password) { context in
            for number in 1...pages {
                let size = sizes[(number - 1) % sizes.count]
                Self.beginPage(context, size: size)
                Self.draw(Self.marker(name, page: number), in: context, at: CGPoint(x: 72, y: size.height - 100))
                context.endPDFPage()
            }
        }
        return url
    }

    /// Eine verschlüsselte PDF, die sich nur mit `password` öffnen lässt.
    @discardableResult
    func encryptedPDF(named name: String = "Encrypted", pages: Int = 2, password: String = "test-password") throws
        -> URL {
        try pdf(named: name, pages: pages, password: password)
    }

    /// Drei Seiten mit Inhaltsverzeichnis (ein Eintrag je Seite), einem internen Link von Seite 1 auf Seite 3 und
    /// einem externen Link auf Seite 2.
    @discardableResult
    func linkedPDF(named name: String = "Linked") throws -> URL {
        let url = url("\(name).pdf")
        try writePDF(to: url) { context in
            let size = Self.a4
            for number in 1...3 {
                Self.beginPage(context, size: size)
                Self.draw(Self.marker(name, page: number), in: context, at: CGPoint(x: 72, y: size.height - 100))
                switch number {
                case 1:
                    Self.draw("Go to page 3", in: context, at: CGPoint(x: 72, y: 400))
                    context.setDestination("page3" as CFString, for: Self.linkRect)
                case 2:
                    Self.draw("Visit example.com", in: context, at: CGPoint(x: 72, y: 400))
                    context.setURL(Self.externalLink as CFURL, for: Self.linkRect)
                default:
                    context.addDestination("page3" as CFString, at: CGPoint(x: 0, y: size.height))
                }
                context.endPDFPage()
            }
            CGPDFContextSetOutline(context, Self.outline(name: name, pages: 3) as CFDictionary)
        }
        return url
    }

    static let linkRect = CGRect(x: 72, y: 395, width: 200, height: 20)
    static let externalLink = URL(string: "https://example.com/")!

    /// Eine Seite mit einem Textfeld (`name`, Wert `Jane Doe`) und einem angekreuzten Kontrollkästchen (`agree`).
    @discardableResult
    func formPDF(named name: String = "Form") throws -> URL {
        let blank = try pdf(named: "\(name)-blank", pages: 1)
        let document = try unwrap(PDFDocument(url: blank))
        let page = try unwrap(document.page(at: 0))

        let textField = PDFAnnotation(
            bounds: CGRect(x: 72, y: 600, width: 200, height: 24), forType: .widget, withProperties: nil)
        textField.widgetFieldType = .text
        textField.fieldName = "name"
        textField.widgetStringValue = "Jane Doe"
        page.addAnnotation(textField)

        let checkbox = PDFAnnotation(
            bounds: CGRect(x: 72, y: 560, width: 18, height: 18), forType: .widget, withProperties: nil)
        checkbox.widgetFieldType = .button
        checkbox.widgetControlType = .checkBoxControl
        checkbox.fieldName = "agree"
        checkbox.buttonWidgetState = .onState
        page.addAnnotation(checkbox)

        let url = url("\(name).pdf")
        guard document.write(to: url) else { throw CorpusError.writeFailed(url) }
        try FileManager.default.removeItem(at: blank)
        return url
    }

    /// Eine Seite, die nur aus einem Bild besteht, wie ein Scan ohne Textebene.
    @discardableResult
    func scannedPDF(named name: String = "Scanned") throws -> URL {
        let url = url("\(name).pdf")
        let image = try Self.makeImage(size: CGSize(width: 400, height: 560))
        try writePDF(to: url) { context in
            Self.beginPage(context, size: Self.a4)
            context.draw(image, in: CGRect(origin: .zero, size: Self.a4))
            context.endPDFPage()
        }
        return url
    }

    /// Text in mehreren Schriften und Richtungen: Ligaturen, Umlaute, Hebräisch und Arabisch (rechts nach links).
    static let mixedScriptLines = [
        "office affinity ffi",
        "Grüße aus Köln",
        "שלום עולם",
        "مرحبا بالعالم",
    ]

    @discardableResult
    func mixedScriptPDF(named name: String = "MixedScripts") throws -> URL {
        let url = url("\(name).pdf")
        try writePDF(to: url) { context in
            Self.beginPage(context, size: Self.a4)
            for (offset, line) in Self.mixedScriptLines.enumerated() {
                Self.draw(line, in: context, at: CGPoint(x: 72, y: 700 - CGFloat(offset) * 40))
            }
            context.endPDFPage()
        }
        return url
    }

    /// Eine Datei mit PDF-Kopf, die nach wenigen Bytes abbricht.
    @discardableResult
    func truncatedPDF(named name: String = "Truncated") throws -> URL {
        let complete = try Data(contentsOf: pdf(named: "\(name)-complete", pages: 2))
        let url = url("\(name).pdf")
        try complete.prefix(200).write(to: url)
        try FileManager.default.removeItem(at: self.url("\(name)-complete.pdf"))
        return url
    }

    /// Eine Textdatei mit der Endung `.pdf`.
    @discardableResult
    func notAPDF(named name: String = "NotAPDF") throws -> URL {
        let url = url("\(name).pdf")
        try Data("This is not a PDF.\n".utf8).write(to: url)
        return url
    }

    /// Eine leere Datei mit der Endung `.pdf`.
    @discardableResult
    func emptyFile(named name: String = "Empty") throws -> URL {
        let url = url("\(name).pdf")
        try Data().write(to: url)
        return url
    }

    // MARK: Bilder

    enum ImageFormat: String, CaseIterable {
        case png, jpeg, heic

        var type: UTType {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .heic: .heic
            }
        }

        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    }

    /// Ein einfarbiges Bild mit einer Markierung oben links, damit Drehungen erkennbar sind.
    @discardableResult
    func image(named name: String, format: ImageFormat, size: CGSize = CGSize(width: 300, height: 200)) throws -> URL {
        let url = url("\(name).\(format.fileExtension)")
        let image = try Self.makeImage(size: size)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw CorpusError.writeFailed(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CorpusError.writeFailed(url) }
        return url
    }

    // MARK: Hilfen

    enum CorpusError: Error {
        case writeFailed(URL)
        case missing(String)
    }

    private func writePDF(to url: URL, password: String? = nil, draw: (CGContext) -> Void) throws {
        var info: [CFString: Any] = [kCGPDFContextCreator: "PDF to me tests"]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
            info[kCGPDFContextEncryptionKeyLength] = 128
        }
        var mediaBox = CGRect(origin: .zero, size: Self.a4)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw CorpusError.writeFailed(url)
        }
        draw(context)
        context.closePDF()
    }

    private static func beginPage(_ context: CGContext, size: CGSize) {
        var box = CGRect(origin: .zero, size: size)
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
    }

    private static func draw(_ text: String, in context: CGContext, at point: CGPoint) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributed = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static func outline(name: String, pages: Int) -> [CFString: Any] {
        let children: [[CFString: Any]] = (1...pages).map { number in
            [kCGPDFOutlineTitle: "Chapter \(number)", kCGPDFOutlineDestination: number]
        }
        return [kCGPDFOutlineChildren: children]
    }

    static func makeImage(size: CGSize) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CorpusError.missing("bitmap context") }
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: size.height * 0.75, width: size.width * 0.25, height: size.height * 0.25))
        guard let image = context.makeImage() else { throw CorpusError.missing("image") }
        return image
    }

    private func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw CorpusError.missing(String(describing: T.self)) }
        return value
    }
}
