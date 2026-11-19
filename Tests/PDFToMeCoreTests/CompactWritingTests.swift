import PDFKit
import XCTest
@testable import PDFToMeCore

/// Verlustfreies Verkleinern beim Schreiben (`WriteOptions.compact`).
final class CompactWritingTests: XCTestCase {
    private var corpus: TestCorpus!

    override func setUpWithError() throws {
        corpus = try TestCorpus()
    }

    override func tearDown() {
        corpus.remove()
        super.tearDown()
    }

    private func write(_ plan: DocumentPlan, _ contents: SourceContents, compact: Bool) throws -> URL {
        let url = corpus.url("Out-\(UUID().uuidString).pdf")
        try QPDFKitWriter().compose(plan, contents: contents, to: url, options: WriteOptions(compact: compact))
        return url
    }

    private func size(_ url: URL) throws -> Int {
        try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    private func load(_ url: URL) throws -> (DocumentPlan, SourceContents) {
        let loaded = try SourceLoader.load(url)
        return (try DocumentPlan(source: loaded.source), [loaded.source.id: loaded.content])
    }

    /// Namen der Bilder (XObjects) in den Ressourcen einer Seite.
    private func imageNames(_ url: URL, page: Int) throws -> Set<String> {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let dictionary = try XCTUnwrap(document.page(at: page + 1)?.dictionary)
        var resources: CGPDFDictionaryRef?
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects
        else { return [] }
        var names = Set<String>()
        withUnsafeMutablePointer(to: &names) { pointer in
            CGPDFDictionaryApplyFunction(xobjects, { key, _, info in
                info!.assumingMemoryBound(to: Set<String>.self).pointee.insert(String(cString: key))
            }, pointer)
        }
        return names
    }

    // MARK: Testdateien

    /// Text-PDF mit unkomprimierten Inhalten, wie sie manche Programme schreiben.
    private func uncompressedTextPDF(pages: Int) throws -> URL {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [\((0..<pages).map { "\($0 * 2 + 4) 0 R" }.joined(separator: " "))] "
                           + "/Count \(pages) >>",
                       "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
        for number in 1...pages {
            let lines = (0..<40).map { line in
                "BT /F1 11 Tf 56 \(780 - line * 18) Td (Seite \(number), Zeile \(line): Lorem ipsum dolor sit amet) Tj ET"
            }.joined(separator: "\n")
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents \(objects.count + 2) 0 R "
                           + "/Resources << /Font << /F1 3 0 R >> >> >>")
            objects.append("<< /Length \(lines.utf8.count) >>\nstream\n\(lines)\nendstream")
        }
        let url = corpus.url("Uncompressed.pdf")
        try Data(TestCorpus.pdfFile(objects: objects).utf8).write(to: url)
        return url
    }

    /// Zwei Seiten mit einem gemeinsamen Ressourcen-Verzeichnis und zwei Bildern; Seite 1 zeigt nur `/ImA`,
    /// Seite 2 nur `/ImB`. Die Bilddaten sind zufällig, damit sie sich nicht komprimieren lassen.
    private func sharedResourcesPDF() throws -> URL {
        func image() -> String {
            var generator = SystemRandomNumberGenerator()
            let hex = (0..<(100 * 100)).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
                .joined() + ">"
            return "<< /Type /XObject /Subtype /Image /Width 100 /Height 100 /ColorSpace /DeviceGray "
                + "/BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(hex.utf8.count) >>\nstream\n\(hex)\nendstream"
        }
        func content(_ name: String) -> String {
            let text = "q 200 0 0 200 100 500 cm /\(name) Do Q"
            return "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [4 0 R 5 0 R] /Count 2 >>",
            "<< /XObject << /ImA 8 0 R /ImB 9 0 R >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 6 0 R /Resources 3 0 R >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 7 0 R /Resources 3 0 R >>",
            content("ImA"), content("ImB"), image(), image(),
        ]
        let url = corpus.url("Shared.pdf")
        try Data(TestCorpus.pdfFile(objects: objects).utf8).write(to: url)
        return url
    }

    // MARK: Tests

    func testCompactIsSmallerAndKeepsText() throws {
        let (plan, contents) = try load(uncompressedTextPDF(pages: 5))
        let plain = try write(plan, contents, compact: false)
        let compact = try write(plan, contents, compact: true)
        XCTAssertLessThan(try size(compact), try size(plain))
        let before = try XCTUnwrap(PDFDocument(url: plain)), after = try XCTUnwrap(PDFDocument(url: compact))
        XCTAssertEqual(after.pageCount, 5)
        for index in 0..<5 {
            XCTAssertEqual(after.page(at: index)?.string, before.page(at: index)?.string)
        }
        XCTAssertTrue(after.page(at: 2)?.string?.contains("Seite 3, Zeile 39") ?? false)
    }

    /// Wird nur Seite 1 gespeichert, fällt das Bild von Seite 2 aus der Datei, obwohl beide Seiten in der Quelle
    /// dieselben Ressourcen hatten.
    func testUnusedResourcesOfOtherPagesAreDropped() throws {
        let (full, contents) = try load(sharedResourcesPDF())
        let plan = try full.extracting([full.pages[0].id])
        let plain = try write(plan, contents, compact: false)
        let compact = try write(plan, contents, compact: true)
        XCTAssertEqual(try imageNames(plain, page: 0), ["ImA", "ImB"])
        XCTAssertEqual(try imageNames(compact, page: 0), ["ImA"])
        // Ein Bild hat 10 000 Byte zufällige Daten; eines davon ist weg.
        XCTAssertLessThan(try size(compact), try size(plain) - 9000)
    }

    /// Gemeinsame Ressourcen werden pro Seite gekürzt, nie für alle: Jede Seite behält ihr Bild, auch eine doppelte.
    func testSharedResourcesStayCompleteForEveryPage() throws {
        var (plan, contents) = try load(sharedResourcesPDF())
        let source = plan.sources[0]
        try plan.insert([PageRef(source: source.id, index: 0)], at: 2)
        // Über die Speicher-Pipeline, also mit Prüfung; `compact` ist die Vorgabe.
        let folder = corpus.url("Saved")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = try SavePipeline(writer: QPDFKitWriter())
            .save(plan, contents: contents, in: folder, baseName: "Shared").url
        XCTAssertEqual(try imageNames(url, page: 0), ["ImA"])
        XCTAssertEqual(try imageNames(url, page: 1), ["ImB"])
        XCTAssertEqual(try imageNames(url, page: 2), ["ImA"])
    }
}
