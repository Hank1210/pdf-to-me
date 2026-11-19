import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit

/// Gescannte Seiten ohne Textebene: Bilder von Text, wie sie ein Scanner liefert. Für die Texterkennung.
extension TestCorpus {
    /// Weißes Bild mit schwarzen Textzeilen von oben nach unten (Helvetica, gut lesbar für Vision).
    static func textImage(lines: [String], size: CGSize = CGSize(width: 1240, height: 1754)) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CorpusError.missing("bitmap context") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let fontSize = min(size.width, size.height) / 18
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        for (number, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: fontSize, y: size.height - fontSize * 2 * CGFloat(number + 1))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        guard let image = context.makeImage() else { throw CorpusError.missing("image") }
        return image
    }

    /// Eine Scan-PDF (eine Seite pro Eintrag in `pages`), jede Seite ein Bild ihrer Textzeilen, ohne Textebene.
    /// `rotated`: Der Inhalt liegt quer auf der Seite, und die Seite trägt `/Rotate 90`, sodass sie aufrecht
    /// angezeigt wird, wie bei einem quer eingelegten Scan. `cropToTopHalf`: Der sichtbare Ausschnitt
    /// (CropBox) ist die obere Hälfte.
    @discardableResult
    func scannedTextPDF(
        named name: String, pages: [[String]], rotated: Bool = false, cropToTopHalf: Bool = false
    ) throws -> URL {
        let url = url("\(name).pdf")
        let images = try pages.map { try Self.textImage(lines: $0) }
        try writePDF(to: url) { context in
            for image in images {
                if rotated {
                    // Seite quer; Bild um 90° gegen den Uhrzeigersinn gedreht, damit es mit /Rotate 90 aufrecht steht.
                    Self.beginPage(context, size: Self.a4Landscape)
                    context.saveGState()
                    context.translateBy(x: Self.a4.height, y: 0)
                    context.rotate(by: .pi / 2)
                    context.draw(image, in: CGRect(origin: .zero, size: Self.a4))
                    context.restoreGState()
                } else {
                    Self.beginPage(context, size: Self.a4)
                    context.draw(image, in: CGRect(origin: .zero, size: Self.a4))
                }
                context.endPDFPage()
            }
        }
        guard rotated || cropToTopHalf else { return url }
        // Drehung und Ausschnitt setzt PDFKit; erlaubt, weil es nur Testdaten herstellt.
        guard let document = PDFDocument(url: url) else { throw CorpusError.missing("scan document") }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if rotated { page.rotation = 90 }
            if cropToTopHalf {
                let media = page.bounds(for: .mediaBox)
                page.setBounds(CGRect(x: 0, y: media.height / 2, width: media.width, height: media.height / 2),
                               for: .cropBox)
            }
        }
        guard document.write(to: url) else { throw CorpusError.writeFailed(url) }
        return url
    }

    /// Ein Bild mit Textzeilen als Datei, z. B. ein fotografierter Beleg.
    func textImageFile(named name: String, lines: [String], size: CGSize) throws -> URL {
        let url = url("\(name).png")
        let image = try Self.textImage(lines: lines, size: size)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, ImageFormat.png.type.identifier as CFString, 1, nil)
        else { throw CorpusError.writeFailed(url) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CorpusError.writeFailed(url) }
        return url
    }
}
