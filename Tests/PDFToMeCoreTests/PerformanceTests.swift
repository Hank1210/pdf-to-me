import PDFKit
import XCTest
@testable import PDFToMeCore

/// Leistung bei großen Dokumenten (README: 500 Seiten öffnen in unter 2 Sekunden, Miniaturen scrollen flüssig).
/// Die Grenzen sind großzügig, damit die Tests auch auf langsameren Macs stabil sind; die gemessenen Werte stehen
/// in der Testausgabe.
final class PerformanceTests: XCTestCase {
    private var corpus: TestCorpus!

    override func setUpWithError() throws {
        corpus = try TestCorpus()
    }

    override func tearDown() {
        corpus.remove()
        super.tearDown()
    }

    private func seconds(_ label: String, _ body: () throws -> Void) rethrows -> Double {
        let start = Date()
        try body()
        let elapsed = Date().timeIntervalSince(start)
        print("PERF \(label): \(String(format: "%.3f", elapsed)) s")
        return elapsed
    }

    func testFiveHundredPages() throws {
        let url = try corpus.pdf(named: "Large", pages: 500, sizes: [TestCorpus.a4, TestCorpus.a4Landscape])
        var document: WorkingDocument!

        XCTAssertLessThan(try seconds("open 500 pages") {
            document = try WorkingDocument(opening: url, sessionStore: nil)
        }, 2)

        // Flüssiges Scrollen: Eine Miniatur muss deutlich schneller entstehen als ein Bild (16 ms bei 60 Hz).
        let preview = document.preview.document
        let thumbnails = try seconds("100 thumbnails") {
            for index in stride(from: 0, to: 500, by: 5) {
                _ = preview.page(at: index)?.thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox)
            }
        }
        XCTAssertLessThan(thumbnails / 100, 0.016, "per thumbnail")

        XCTAssertLessThan(seconds("search") {
            XCTAssertEqual(DocumentSearch.count(DocumentSearch.search("Large page 499", in: preview)), 1)
        }, 2)

        XCTAssertLessThan(try seconds("move page and rebuild preview") {
            try document.change { try $0.move([$0.pages[0].id], to: 500) }
        }, 1)

        let output = corpus.url("Output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        XCTAssertLessThan(try seconds("save and check 500 pages") {
            _ = try SavePipeline(writer: QPDFKitWriter()).save(
                document.plan, contents: document.contents, in: output, baseName: "Large (edited)")
        }, 10)
    }

    /// Gescannte Seiten (A4 mit 300 dpi als Bild) sind der aufwendigste Fall für Miniaturen.
    func testScannedPagesThumbnails() throws {
        let url = corpus.url("Scans.pdf")
        let image = try Self.noiseImage(width: 2480, height: 3508)
        var box = CGRect(origin: .zero, size: TestCorpus.a4)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<20 {
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()

        let document = try WorkingDocument(opening: url, sessionStore: nil)
        let preview = document.preview.document
        let elapsed = seconds("20 scanned thumbnails") {
            for index in 0..<20 {
                _ = preview.page(at: index)?.thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox)
            }
        }
        print("PERF per scanned thumbnail: \(String(format: "%.1f", elapsed / 20 * 1000)) ms")
    }

    private static func noiseImage(width: Int, height: Int) throws -> CGImage {
        var generator = SeededGenerator(seed: 7)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 180...255, using: &generator) }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }
}
