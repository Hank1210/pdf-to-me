import CoreGraphics
import DocKit
import Foundation
import PDFKit

/// Eine einseitige PDF, die nur die unsichtbare Textebene einer erkannten Seite enthält. qpdf legt sie beim
/// Speichern über die Originalseite (`qk_add_page_with_overlay`); die Seite selbst bleibt unverändert.
enum TextLayerPage {
    /// `size` ist die Größe der Seite, wie sie angezeigt wird (sichtbarer Ausschnitt, eigene Drehung der Quelle).
    /// Die Kästen des Ergebnisses beziehen sich auf genau diese Seite (`TextRecognitionRun`).
    static func pdfData(_ page: RecognizedPage, size: CGSize) throws -> Data {
        var mediaBox = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard size.width > 0, size.height > 0,
              let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw AssemblyError.textLayerFailed }
        // Die Seitengröße muss je Seite angegeben werden; ohne sie nimmt CoreGraphics US-Letter.
        var box = mediaBox
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        InvisibleTextLayer.draw(page, over: mediaBox, in: context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Angezeigte Größe einer Quellseite, wie `TextRecognitionRun` sie rastert.
    static func displayedSize(of content: LoadedSource.Content?, pageIndex: Int) -> CGSize? {
        switch content {
        case let .pdf(document, _):
            guard let page = document.page(at: pageIndex) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            return page.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        case let .image(image, orientation):
            // EXIF-Ausrichtungen 5…8 tauschen Breite und Höhe.
            let turned = orientation.rawValue >= 5
            let size = turned ? CGSize(width: image.height, height: image.width)
                              : CGSize(width: image.width, height: image.height)
            return ImagePage.pageSize(forImageOf: size)
        case nil:
            return nil
        }
    }
}
