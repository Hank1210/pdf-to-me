import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bilder verkleinern beim Speichern („Verkleinert speichern“): auf höchstens 150 dpi, als JPEG mit Qualität 75 %.
///
/// Die Regeln stehen hier, die Mechanik (Bilder finden, dekodieren, ersetzen) in der qpdf-Brücke. Gemessen wird
/// vorsichtig an der ganzen Seite: Ein Bild behält höchstens so viele Pixel, wie 150 dpi über die längere Seite
/// der größten Seite ergeben, auf der es steht. Ein kleiner platziertes Bild behält dadurch mehr als 150 dpi und
/// wird nie zu grob. Text, Links, Formulare und Textebenen bleiben unberührt, nur Bilddaten werden ersetzt.
public enum ImageReduction {
    public static let dpi: Double = 150
    public static let jpegQuality: Double = 0.75
    /// Erst ab diesem Verhältnis über der Grenze wird verkleinert. Knapp darüber lohnt das erneute Kodieren nicht.
    static let tolerance: Double = 1.1

    /// Was über ein Bild bekannt ist (aus der Brücke, `QKImageInfo`).
    public struct Candidate: Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// 1 (Grau), 3 (RGB) oder 0 (anderer Farbraum).
        public var components: Int
        public var bitsPerComponent: Int
        public var hasMask: Bool
        public var hasDecode: Bool
        /// Längere Seite der größten Seite, auf der das Bild steht, in Punkt (1/72 Zoll).
        public var pageLongSide: Double

        public init(width: Int, height: Int, components: Int, bitsPerComponent: Int, hasMask: Bool = false,
                    hasDecode: Bool = false, pageLongSide: Double) {
            self.width = width
            self.height = height
            self.components = components
            self.bitsPerComponent = bitsPerComponent
            self.hasMask = hasMask
            self.hasDecode = hasDecode
            self.pageLongSide = pageLongSide
        }
    }

    /// Die Zielgröße in Pixeln, oder `nil`, wenn das Bild bleibt, wie es ist.
    ///
    /// Unverändert bleiben: Schwarzweiß-Bilder (1 Bit, als JPEG größer und unscharf), Bilder mit Maske oder
    /// eigenen `/Decode`-Werten, CMYK, Farbpaletten und andere Farbräume sowie Bilder, die schon bei 150 dpi oder
    /// darunter liegen.
    public static func targetSize(for image: Candidate) -> (width: Int, height: Int)? {
        guard image.components == 1 || image.components == 3, image.bitsPerComponent == 8,
              !image.hasMask, !image.hasDecode, image.width > 0, image.height > 0, image.pageLongSide > 0
        else { return nil }
        let limit = (image.pageLongSide / 72 * dpi).rounded(.up)
        let longSide = Double(max(image.width, image.height))
        guard longSide > limit * tolerance else { return nil }
        let scale = limit / longSide
        return (max(1, Int((Double(image.width) * scale).rounded())),
                max(1, Int((Double(image.height) * scale).rounded())))
    }

    /// Skaliert dekodierte Pixel (8 Bit, `components` Komponenten, zeilenweise ohne Auffüllung) auf die Zielgröße
    /// und kodiert sie als JPEG. Die Farbwerte werden nicht umgerechnet; der Farbraum im PDF bleibt gültig.
    public static func jpeg(pixels: Data, width: Int, height: Int, components: Int,
                            targetWidth: Int, targetHeight: Int) -> Data? {
        guard components == 1 || components == 3, pixels.count == width * height * components,
              targetWidth > 0, targetHeight > 0 else { return nil }
        let gray = components == 1
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: pixels as CFData),
              let source = CGImage(width: width, height: height, bitsPerComponent: 8,
                                   bitsPerPixel: 8 * components, bytesPerRow: width * components, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let context = CGContext(data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue
                                                       : CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, scaled, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
