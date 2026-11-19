import DocKit
import ImageIO
import PDFKit
import XCTest
@testable import PDFToMeCore

/// Bilder verkleinern beim Speichern (`WriteOptions.reduceImages`, `ImageReduction`).
final class ImageReductionTests: XCTestCase {
    private var corpus: TestCorpus!

    override func setUpWithError() throws {
        corpus = try TestCorpus()
    }

    override func tearDown() {
        corpus.remove()
        Localization.current = .de
        super.tearDown()
    }

    // MARK: Hilfen

    private struct ImageInfo: Equatable {
        var width: Int
        var height: Int
        var bits: Int
        var filter: String?
    }

    /// Die Bilder in den Ressourcen einer Seite (ab 0), nach Namen; Formular-XObjects zählen nicht.
    private func images(_ url: URL, page: Int) throws -> [String: ImageInfo] {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let dictionary = try XCTUnwrap(document.page(at: page + 1)?.dictionary)
        var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects
        else { return [:] }
        var found: [String: ImageInfo] = [:]
        withUnsafeMutablePointer(to: &found) { pointer in
            CGPDFDictionaryApplyFunction(xobjects, { key, object, info in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dict = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype,
                      String(cString: subtype) == "Image" else { return }   // Formulare, z. B. die Textebene
                var width = 0, height = 0, bits = 0
                var filter: UnsafePointer<CChar>?
                CGPDFDictionaryGetInteger(dict, "Width", &width)
                CGPDFDictionaryGetInteger(dict, "Height", &height)
                CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bits)
                CGPDFDictionaryGetName(dict, "Filter", &filter)
                info!.assumingMemoryBound(to: [String: ImageInfo].self).pointee[String(cString: key)] =
                    ImageInfo(width: width, height: height, bits: bits, filter: filter.map { String(cString: $0) })
            }, pointer)
        }
        return found
    }

    private func size(_ url: URL) throws -> Int64 {
        try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value)
    }

    private func load(_ urls: URL...) throws -> (DocumentPlan, SourceContents) {
        var plan: DocumentPlan?
        var contents: SourceContents = [:]
        for url in urls {
            let loaded = try SourceLoader.load(url)
            contents[loaded.source.id] = loaded.content
            if plan == nil {
                plan = try DocumentPlan(source: loaded.source)
            } else {
                try plan!.insertPages(of: loaded.source, at: plan!.pages.count)
            }
        }
        return (try XCTUnwrap(plan), contents)
    }

    private func write(_ plan: DocumentPlan, _ contents: SourceContents, reduce: Bool) throws -> URL {
        let url = corpus.url("Out-\(UUID().uuidString).pdf")
        try QPDFKitWriter().compose(plan, contents: contents, to: url, options: WriteOptions(reduceImages: reduce))
        return url
    }

    private func saveFolder() throws -> URL {
        let folder = corpus.url("Saved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    enum ScanKind { case scan, pattern }

    /// Ein Graubild in A4 mit 300 dpi (2480 × 3508 Pixel).
    /// `.scan`: helles Papier mit dunklen Balken und leichtem Rauschen, wie ein echter Scan.
    /// `.pattern`: Schachbrett aus 6-Pixel-Feldern; mit Flate winzig, als JPEG teuer.
    private func scanImage(_ kind: ScanKind) throws -> CGImage {
        let width = 2480, height = 3508
        var pixels = [UInt8](repeating: 0, count: width * height)
        var seed: UInt32 = 4711
        pixels.withUnsafeMutableBufferPointer { buffer in
            for y in 0..<height {
                let bar = y % 500 > 300
                for x in 0..<width {
                    switch kind {
                    case .scan:
                        seed = seed &* 1_664_525 &+ 1_013_904_223
                        let noise = Int(seed >> 28) - 8
                        buffer[y * width + x] = UInt8(clamping: (bar && x > 200 && x < 2200 ? 40 : 235) + noise)
                    case .pattern:
                        buffer[y * width + x] = (x / 6 + y / 6) % 2 == 0 ? 0 : 255
                    }
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Eine A4-Seite, die das Bild ganz füllt.
    private func scanPDF(named name: String, kind: ScanKind = .scan) throws -> URL {
        let url = corpus.url("\(name).pdf")
        let image = try scanImage(kind)
        try corpus.writePDF(to: url) { context in
            TestCorpus.beginPage(context, size: TestCorpus.a4)
            context.draw(image, in: CGRect(origin: .zero, size: TestCorpus.a4))
            context.endPDFPage()
        }
        return url
    }

    /// Eine Seite von 100 × 100 pt (Grenze 209 Pixel) mit Bildern von 400 × 400 Pixeln, die bleiben müssen, und
    /// einem Graubild ohne Besonderheiten, das verkleinert wird. Bilddaten zufällig, damit JPEG kleiner ist.
    private func excludedImagesPDF() throws -> URL {
        func hex(_ count: Int) -> String {
            var generator = SystemRandomNumberGenerator()
            return (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
                .joined() + ">"
        }
        func image(_ attributes: String, bytes: Int) -> String {
            let data = hex(bytes)
            return "<< /Type /XObject /Subtype /Image /Width 400 /Height 400 \(attributes) /Filter /ASCIIHexDecode "
                + "/Length \(data.utf8.count) >>\nstream\n\(data)\nendstream"
        }
        let names = ["Plain", "OneBit", "Masked", "CMYK", "Decoded"]
        let drawing = names.map { "q 100 0 0 100 0 0 cm /\($0) Do Q" }.joined(separator: "\n")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R /Resources << /XObject << "
                + "/Plain 5 0 R /OneBit 6 0 R /Masked 7 0 R /CMYK 8 0 R /Decoded 9 0 R >> >> >>",
            "<< /Length \(drawing.utf8.count) >>\nstream\n\(drawing)\nendstream",
            image("/ColorSpace /DeviceGray /BitsPerComponent 8", bytes: 160_000),
            image("/ColorSpace /DeviceGray /BitsPerComponent 1", bytes: 20_000),
            image("/ColorSpace /DeviceGray /BitsPerComponent 8 /SMask 10 0 R", bytes: 160_000),
            image("/ColorSpace /DeviceCMYK /BitsPerComponent 8", bytes: 640_000),
            image("/ColorSpace /DeviceGray /BitsPerComponent 8 /Decode [1 0]", bytes: 160_000),
            image("/ColorSpace /DeviceGray /BitsPerComponent 8", bytes: 160_000),   // Maske von /Masked
        ]
        let url = corpus.url("Excluded.pdf")
        try Data(TestCorpus.pdfFile(objects: objects).utf8).write(to: url)
        return url
    }

    // MARK: Regeln

    func testTargetSizeForA4ScanAt300Dpi() throws {
        let scan = ImageReduction.Candidate(width: 2480, height: 3508, components: 3, bitsPerComponent: 8,
                                            pageLongSide: 842)
        let target = try XCTUnwrap(ImageReduction.targetSize(for: scan))
        // 842 pt = 11,69 Zoll; bei 150 dpi 1755 Pixel auf der langen Seite.
        XCTAssertEqual(target.height, 1755)
        XCTAssertEqual(target.width, 1241)
        // Grau ebenso.
        XCTAssertNotNil(ImageReduction.targetSize(for: .init(width: 2480, height: 3508, components: 1,
                                                             bitsPerComponent: 8, pageLongSide: 842)))
    }

    func testImagesThatStayUnchanged() {
        func target(_ change: (inout ImageReduction.Candidate) -> Void) -> (width: Int, height: Int)? {
            var image = ImageReduction.Candidate(width: 2480, height: 3508, components: 3, bitsPerComponent: 8,
                                                 pageLongSide: 842)
            change(&image)
            return ImageReduction.targetSize(for: image)
        }
        XCTAssertNil(target { $0.bitsPerComponent = 1 }, "Schwarzweiß")
        XCTAssertNil(target { $0.bitsPerComponent = 16 }, "16 Bit")
        XCTAssertNil(target { $0.components = 0 }, "CMYK, Farbpalette und andere Farbräume")
        XCTAssertNil(target { $0.hasMask = true }, "Maske")
        XCTAssertNil(target { $0.hasDecode = true }, "/Decode")
        XCTAssertNil(target { $0.width = 1240; $0.height = 1754 }, "schon 150 dpi")
        XCTAssertNil(target { $0.width = 1300; $0.height = 1840 }, "knapp darüber, innerhalb der Toleranz")
        XCTAssertNil(target { $0.pageLongSide = 0 }, "Seite unbekannt")
    }

    func testJPEGHasTargetSizeAndComponents() throws {
        for components in [1, 3] {
            let pixels = Data((0..<(400 * 300 * components)).map { UInt8($0 % 251) })
            let data = try XCTUnwrap(ImageReduction.jpeg(pixels: pixels, width: 400, height: 300,
                                                         components: components, targetWidth: 200, targetHeight: 150))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 200)
            XCTAssertEqual(image.height, 150)
            XCTAssertEqual(image.colorSpace?.numberOfComponents, components)
        }
        // Falsche Länge: kein Ergebnis statt eines kaputten Bildes.
        XCTAssertNil(ImageReduction.jpeg(pixels: Data(count: 10), width: 400, height: 300, components: 3,
                                         targetWidth: 200, targetHeight: 150))
    }

    // MARK: Schreiben

    func testScanBecomesSmallerAt150Dpi() throws {
        let (plan, contents) = try load(scanPDF(named: "Scan"))
        let plain = try write(plan, contents, reduce: false)
        let reduced = try write(plan, contents, reduce: true)
        let before = try XCTUnwrap(images(plain, page: 0).values.first)
        let after = try XCTUnwrap(images(reduced, page: 0).values.first)
        XCTAssertEqual(before.width, 2480)
        XCTAssertEqual(after, ImageInfo(width: 1241, height: 1755, bits: 8, filter: "DCTDecode"))
        XCTAssertLessThan(try size(reduced), try size(plain))
        // Die Seite ist weiter lesbar und zeigt das Bild (nicht weiß).
        let page = try XCTUnwrap(PDFDocument(url: reduced)?.page(at: 0))
        let thumbnail = page.thumbnail(of: CGSize(width: 60, height: 85), for: .mediaBox)
        let bitmap = try XCTUnwrap(thumbnail.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let dark = (0..<bitmap.pixelsHigh).contains { y in
            (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5 }
        }
        XCTAssertTrue(dark, "die dunklen Balken des Scans fehlen")
    }

    /// Text, Links, Formularfelder, Inhaltsverzeichnis und erkannte Textebene bleiben; die Prüf-Pipeline läuft mit.
    func testEverythingElseIsKept() throws {
        let (loaded, contents) = try load(corpus.linkedPDF(), corpus.formPDF(), scanPDF(named: "Scan"))
        var plan = loaded
        let scanPage = try XCTUnwrap(plan.pages.last)
        try plan.recognizeText([scanPage.id])
        let cache = TextRecognitionCache()
        let source = try XCTUnwrap(plan.source(of: scanPage))
        cache[.init(source: source, page: scanPage)] = RecognizedPage(lines: [
            RecognizedLine(text: "Stromrechnung Mai", box: CGRect(x: 0.1, y: 0.85, width: 0.5, height: 0.03)),
        ])
        let options = WriteOptions(textLayers: cache, reduceImages: true)
        let pipeline = SavePipeline(writer: QPDFKitWriter())
        let result = try pipeline.save(plan, contents: contents, in: saveFolder(), baseName: "Alles", options: options)
        let written = try XCTUnwrap(PDFDocument(url: result.url))
        XCTAssertTrue(written.page(at: plan.pages.count - 1)?.string?.contains("Stromrechnung Mai") ?? false)
        XCTAssertEqual(try images(result.url, page: plan.pages.count - 1).values.first?.filter, "DCTDecode")
        // Vergleich ohne Verkleinerung: größer.
        let before = try pipeline.unreducedSize(plan, contents: contents, near: saveFolder(), options: options)
        XCTAssertGreaterThan(before, try size(result.url))
    }

    /// Ausgenommene Bilder bleiben unverändert; ein gewöhnliches Graubild daneben wird verkleinert.
    func testExcludedImagesStayUnchanged() throws {
        let (plan, contents) = try load(excludedImagesPDF())
        let plain = try images(write(plan, contents, reduce: false), page: 0)
        let reduced = try images(write(plan, contents, reduce: true), page: 0)
        XCTAssertEqual(reduced["Plain"], ImageInfo(width: 209, height: 209, bits: 8, filter: "DCTDecode"))
        for name in ["OneBit", "Masked", "CMYK", "Decoded"] {
            XCTAssertEqual(reduced[name], plain[name], name)
            XCTAssertEqual(reduced[name]?.width, 400, name)
        }
    }

    /// Ein Bild wird nur ersetzt, wenn es kleiner wird: Ein Schachbrett ist mit Flate winzig, als JPEG nicht.
    func testImageIsKeptWhenJPEGWouldBeLarger() throws {
        let (plan, contents) = try load(scanPDF(named: "Muster", kind: .pattern))
        let plain = try write(plan, contents, reduce: false)
        let reduced = try write(plan, contents, reduce: true)
        XCTAssertEqual(try images(reduced, page: 0), try images(plain, page: 0))
        XCTAssertEqual(try images(reduced, page: 0).values.first?.width, 2480)
    }

    /// Dasselbe Bild auf mehreren Seiten wird einmal verkleinert und bleibt einmal in der Datei.
    func testSharedImageIsReducedOnce() throws {
        let (single, contents) = try load(scanPDF(named: "Scan"))
        var plan = single
        try plan.insert([PageRef(source: plan.sources[0].id, index: 0)], at: 1)
        let once = try write(single, contents, reduce: true)
        let twice = try write(plan, contents, reduce: true)
        XCTAssertEqual(try images(twice, page: 0).values.first?.width, 1241)
        XCTAssertEqual(try images(twice, page: 1).values.first?.width, 1241)
        XCTAssertLessThan(try size(twice), try size(once) * 3 / 2)
    }

    /// Ein fotoähnliches RGB-Bild: Verlauf, viele farbige Kreise, leichtes Rauschen. Immer gleich (fester Startwert).
    private func photo(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        var seed: UInt32 = 7
        func next() -> CGFloat {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return CGFloat(seed >> 8) / CGFloat(1 << 24)
        }
        let gradient = try XCTUnwrap(CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [CGColor(red: 0.15, green: 0.35, blue: 0.6, alpha: 1),
                     CGColor(red: 0.75, green: 0.6, blue: 0.3, alpha: 1)] as CFArray, locations: nil))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        for _ in 0..<400 {
            let size = 20 + next() * 200
            context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 0.85))
            context.fillEllipse(in: CGRect(x: next() * CGFloat(width), y: next() * CGFloat(height),
                                           width: size, height: size))
        }
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for index in 0..<(width * height * 4) where index % 4 != 3 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            data[index] = UInt8(clamping: Int(data[index]) + Int(seed >> 29) - 4)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func rgbPixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let rgba = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var rgb = Data(count: image.width * image.height * 3)
        rgb.withUnsafeMutableBytes { buffer in
            for pixel in 0..<(image.width * image.height) {
                for channel in 0..<3 { buffer[pixel * 3 + channel] = rgba[pixel * 4 + channel] }
            }
        }
        return rgb
    }

    /// Die Qualität entspricht „JPEG 75“ nach libjpeg (0,53 Bit je Pixel bei diesem Bild), nicht der gut
    /// doppelt so großen ImageIO-Stufe 0,75 (1,31 Bit je Pixel). Ändert Apple die Skala, schlägt dieser Test an.
    func testJPEGSizeMatchesQuality75() throws {
        let image = try photo(width: 1755, height: 1687)
        let jpeg = try XCTUnwrap(ImageReduction.jpeg(
            pixels: rgbPixels(image), width: 1755, height: 1687, components: 3, targetWidth: 1755, targetHeight: 1687))
        let bitsPerPixel = Double(jpeg.count * 8) / Double(1755 * 1687)
        XCTAssertLessThan(bitsPerPixel, 0.8, "JPEG zu groß: \(bitsPerPixel) Bit je Pixel")
    }

    /// Ein gewöhnliches JPEG-Foto mit 186 dpi (wie in vielen Berichten) wird verkleinert und kleiner.
    func testJPEGPhotoAt186DpiGetsSmaller() throws {
        // Quelle als JPEG in der üblichen Qualität, seitenfüllend auf A4: 2194 Pixel auf 842 pt sind 187 dpi.
        let source = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(source, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try photo(width: 1556, height: 2194),
                                   [kCGImageDestinationLossyCompressionQuality: ImageReduction.jpegQuality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let jpegSource = try XCTUnwrap(CGImageSourceCreateWithData(source as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(jpegSource, 0, nil))
        let url = corpus.url("Foto.pdf")
        try corpus.writePDF(to: url) { context in
            TestCorpus.beginPage(context, size: TestCorpus.a4)
            context.draw(image, in: CGRect(origin: .zero, size: TestCorpus.a4))
            context.endPDFPage()
        }
        let (plan, contents) = try load(url)
        let plain = try write(plan, contents, reduce: false)
        let reduced = try write(plan, contents, reduce: true)
        XCTAssertEqual(try images(plain, page: 0).values.first?.filter, "DCTDecode", "Quelle ist kein JPEG")
        XCTAssertEqual(try images(reduced, page: 0).values.first?.height, 1755)
        XCTAssertLessThan(Double(try size(reduced)), Double(try size(plain)) * 0.85)
    }

    // MARK: Meldung und Name

    func testSizeComparisonMessage() {
        Localization.current = .de
        let big = SizeComparison(before: 18_600_000, after: 13_900_000, reference: .original)
        XCTAssertEqual(big.savedPercent, 25)
        XCTAssertTrue(big.message.hasSuffix("(−25 %)."), big.message)
        XCTAssertFalse(big.message.contains("Ohne"), big.message)
        let unreduced = SizeComparison(before: 15_900_000, after: 13_900_000, reference: .unreduced)
        XCTAssertTrue(unreduced.message.hasPrefix("Ohne Bildverkleinerung"), unreduced.message)
        XCTAssertTrue(unreduced.message.hasSuffix("(−13 %)."), unreduced.message)
        let small = SizeComparison(before: 1_000_000, after: 980_000, reference: .original)
        XCTAssertFalse(small.isNoticeable)
        XCTAssertTrue(small.message.hasPrefix("Die Datei ließ sich kaum verkleinern"), small.message)
        Localization.current = .en
        XCTAssertTrue(small.message.hasPrefix("The file could hardly be reduced"), small.message)
        XCTAssertTrue(unreduced.message.hasPrefix("Without reducing images"), unreduced.message)
        XCTAssertEqual(SizeComparison(before: 100, after: 120, reference: .original).savedPercent, 0)
    }

    /// Mit dem Original wird nur verglichen, wenn das Dokument genau eine PDF mit allen ihren Seiten ist.
    func testComparisonUsesTheOriginalOnlyWhenItFits() throws {
        let url = try corpus.pdf(named: "Drei", pages: 3)
        let original = try XCTUnwrap((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init))
        let (plan, contents) = try load(url)
        let pipeline = SavePipeline(writer: QPDFKitWriter())
        let options = WriteOptions(reduceImages: true)

        // Ganz, nur umsortiert: Vergleich mit dem Original.
        var reordered = plan
        try reordered.move([reordered.pages[2].id], to: 0)
        let whole = try pipeline.save(reordered, contents: contents, in: saveFolder(), baseName: "Ganz", options: options)
        let first = try XCTUnwrap(pipeline.sizeComparison(reordered, contents: contents, saved: whole.url,
                                                          options: options))
        XCTAssertEqual(first.reference, .original)
        XCTAssertEqual(first.before, original)

        // Eine Seite gelöscht: Vergleich mit derselben Datei ohne Bildverkleinerung.
        var shorter = plan
        try shorter.remove([shorter.pages[1].id])
        let part = try pipeline.save(shorter, contents: contents, in: saveFolder(), baseName: "Teil", options: options)
        let second = try XCTUnwrap(pipeline.sizeComparison(shorter, contents: contents, saved: part.url,
                                                           options: options))
        XCTAssertEqual(second.reference, .unreduced)
        XCTAssertNotEqual(second.before, original)

        // Eine Seite doppelt oder eine zweite Datei: ebenfalls kein Vergleich mit dem Original.
        var doubled = plan
        try doubled.insert([PageRef(source: plan.sources[0].id, index: 0)], at: 3)
        XCTAssertNil(SizeComparison.originalSize(of: doubled))
        let (merged, _) = try load(url, corpus.pdf(named: "Zwei", pages: 2))
        XCTAssertNil(SizeComparison.originalSize(of: merged))
        XCTAssertEqual(SizeComparison.originalSize(of: plan), original)
    }

    func testReducedFileName() {
        Localization.current = .de
        XCTAssertEqual(FileNaming.reducedBaseName(forOriginal: "Scan.pdf"), "Scan (verkleinert)")
        XCTAssertEqual(FileNaming.reducedBaseName(forOriginal: "Scan (bearbeitet).pdf"), "Scan (verkleinert)")
        XCTAssertEqual(FileNaming.reducedBaseName(forOriginal: "Scan (verkleinert) 2.pdf"), "Scan (verkleinert)")
        Localization.current = .en
        XCTAssertEqual(FileNaming.reducedBaseName(forOriginal: "Scan.pdf"), "Scan (reduced)")
    }
}
