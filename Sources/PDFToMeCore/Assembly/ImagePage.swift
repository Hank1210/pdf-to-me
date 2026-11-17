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
