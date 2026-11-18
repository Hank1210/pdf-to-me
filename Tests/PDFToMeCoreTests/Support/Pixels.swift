import CoreGraphics
import PDFKit
import XCTest

/// Rendert eine Seite in Seitenpunkten (1 Pixel je Punkt) und liest Farben; Ursprung oben links.
struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ page: PDFPage) throws {
        let size = page.bounds(for: .mediaBox).size
        let (width, height) = (Int(size.width), Int(size.height))
        (self.width, self.height) = (width, height)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let rendered: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            page.draw(with: .mediaBox, to: context)
            return true
        }
        guard rendered else { throw XCTSkip("no bitmap context") }
        bytes = buffer
    }

    private func rgb(at point: CGPoint) -> (Int, Int, Int) {
        // Der Bitmap-Kontext speichert die oberste Zeile zuerst.
        let offset = (Int(point.y) * width + Int(point.x)) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    func isWhite(at point: CGPoint) -> Bool { let (r, g, b) = rgb(at: point); return r > 240 && g > 240 && b > 240 }
    func isBlue(at point: CGPoint) -> Bool { let (r, _, b) = rgb(at: point); return b > 150 && r < 100 }
    func isYellow(at point: CGPoint) -> Bool { let (r, g, b) = rgb(at: point); return r > 200 && g > 150 && b < 80 }
}
