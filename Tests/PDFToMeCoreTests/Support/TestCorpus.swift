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

    /// Ein echtes AcroForm-Formular: eine Seite mit dem Text `"<name> page 1"`, einem Textfeld `name` (Wert
    /// `Jane Doe`) und einem angekreuzten Kontrollkästchen `agree`, beide im Formularverzeichnis `/AcroForm /Fields`.
    ///
    /// Von Hand als PDF-Text geschrieben: Mit PDFKit erzeugte Formulare haben kein `/AcroForm` und taugen deshalb
    /// nicht als Prüfstein (so wurde der Formularfehler des früheren `PDFKitWriter` lange übersehen).
    @discardableResult
    func formPDF(named name: String = "Form") throws -> URL {
        let marker = Self.marker(name, page: 1)
        let content = "BT /F1 18 Tf 72 742 Td (\(marker)) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 5 0 R] /NeedAppearances true "
                + "/DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 7 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Annots [4 0 R 5 0 R] /Contents 6 0 R "
                + "/Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Jane Doe) /DA (/Helv 12 Tf 0 g) "
                + "/Rect [72 600 272 624] /P 3 0 R /F 4 >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (agree) /V /Yes /AS /Yes /Rect [72 560 90 578] "
                + "/P 3 0 R /F 4 /AP << /N << /Yes 8 0 R /Off 9 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 18 18] /Length 18 >>\nstream\n0 g 3 3 12 12 re f\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 18 18] /Length 0 >>\nstream\n\nendstream",
        ]
        try Data(Self.pdfFile(objects: objects).utf8).write(to: url("\(name).pdf"))
        return url("\(name).pdf")
    }

    /// Setzt eine PDF-Datei aus Objekten zusammen (Objekt `i + 1` ist `objects[i]`, Objekt 1 der Katalog), mit
    /// korrekter Querverweistabelle.
    static func pdfFile(objects: [String]) -> String {
        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return pdf
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
        // Titel = Dateiname ohne Endung, damit Tests die Übernahme der Metadaten prüfen können.
        var info: [CFString: Any] = [
            kCGPDFContextCreator: "PDF to me tests",
            kCGPDFContextTitle: url.deletingPathExtension().lastPathComponent,
        ]
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
}
