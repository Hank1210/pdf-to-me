import AppKit
import CoreGraphics
import CoreImage
import PDFKit

/// Macht aus einem Bild eine PDF-Seite.
///
/// Die Seite ist A4, hoch oder quer je nach Seitenverhältnis des Bildes. Das Bild wird mit seiner EXIF-Ausrichtung
/// aufgerichtet, ohne Verzerrung eingepasst, mittig gesetzt und bei Bedarf vergrößert; der Rand bleibt weiß.
enum ImagePage {
    static let a4Portrait = CGSize(width: 595, height: 842)
    static let a4Landscape = CGSize(width: 842, height: 595)

    /// Seitengröße für ein Bild dieser Größe (nach Anwendung der Ausrichtung).
    static func pageSize(forImageOf size: CGSize) -> CGSize {
        size.width > size.height ? a4Landscape : a4Portrait
    }

    static func makePage(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> PDFPage {
        let upright = try uprightImage(image, orientation: orientation)
        let size = CGSize(width: upright.width, height: upright.height)
        let nsImage = NSImage(cgImage: upright, size: size)
        let mediaBox = CGRect(origin: .zero, size: pageSize(forImageOf: size))
        guard let page = PDFPage(image: nsImage, options: [.mediaBox: mediaBox, .upscaleIfSmaller: true]) else {
            throw AssemblyError.imagePageFailed
        }
        return page
    }

    /// Eine einseitige PDF mit dem Bild, für Writer, die aus PDF-Dateien zusammensetzen (qpdf). Gleiche Geometrie
    /// wie `makePage`: A4, aufgerichtet, unverzerrt eingepasst (auch vergrößert), mittig, weißer Rand.
    static func pdfData(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> Data {
        let upright = try uprightImage(image, orientation: orientation)
        let imageSize = CGSize(width: upright.width, height: upright.height)
        var mediaBox = CGRect(origin: .zero, size: pageSize(forImageOf: imageSize))
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw AssemblyError.imagePageFailed }
        // Die Seitengröße muss je Seite angegeben werden; ohne sie nimmt CoreGraphics US-Letter.
        var box = mediaBox
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(mediaBox)
        context.interpolationQuality = .high
        context.draw(upright, in: fittedRect(imageSize: imageSize, in: mediaBox))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Das größte Rechteck mit dem Seitenverhältnis des Bildes, mittig in `bounds`.
    static func fittedRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Wendet die EXIF-Ausrichtung an, sodass das Bild aufrecht steht.
    static func uprightImage(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> CGImage {
        guard orientation != .up else { return image }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        guard let result = CIContext(options: [.useSoftwareRenderer: false])
            .createCGImage(oriented, from: oriented.extent)
        else { throw AssemblyError.imagePageFailed }
        return result
    }
}
